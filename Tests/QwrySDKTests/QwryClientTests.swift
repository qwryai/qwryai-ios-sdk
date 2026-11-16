import XCTest
@testable import QwrySDK

/// Answers every request from a queue and records what was sent.
final class MockServer: URLProtocol, @unchecked Sendable {
    struct Sent { let method: String; let path: String; let query: String?; let headers: [String: String]; let body: [String: JSONValue] }
    nonisolated(unsafe) static var answers: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var sent: [Sent] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; data.append(buffer, count: read) }
        }
        MockServer.lock.lock()
        MockServer.sent.append(Sent(method: request.httpMethod ?? "", path: request.url!.path, query: request.url!.query, headers: request.allHTTPHeaderFields ?? [:],
                                    body: (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]))
        let answer = MockServer.answers.removeFirst()
        MockServer.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class MemoryTokens: TokenStore, @unchecked Sendable {
    var token: String?
    func read() -> String? { token }
    func write(_ token: String?) { self.token = token }
}

func sse(_ events: String...) -> String { events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n" }
let finish = #"{"type":"finish","finishReason":"stop","messageMetadata":{"messageId":"m1","conversationId":"c1","userMessageId":"u1","userId":null,"usage":{"credits":1}}}"#

final class QwryClientTests: XCTestCase {
    let tokens = MemoryTokens()

    func client(maxSteps: Int = 10) -> QwryClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockServer.self]
        return QwryClient(agentId: "agent", baseURL: URL(string: "https://example.test/api/sdk")!, configuration: configuration, maxToolLoopSteps: maxSteps, tokens: tokens, deviceId: "device-1")
    }
    override func setUp() { MockServer.answers = []; MockServer.sent = [] }

    func testSendStreamsTheAnswerAndKeepsTheConversation() async throws {
        MockServer.answers = [(200, sse(#"{"type":"start","messageId":"m1"}"#, #"{"type":"text-start","id":"text_0"}"#, #"{"type":"text-delta","id":"text_0","delta":"Hel"}"#, #"{"type":"text-delta","id":"text_0","delta":"lo"}"#, finish)),
                              (200, sse(#"{"type":"text-delta","id":"text_0","delta":"Again"}"#, finish))]
        let client = client()
        let deltas = Deltas()
        let response = try await client.send("Hi") { $0.onTextDelta = { deltas.add($0) } }
        XCTAssertEqual(deltas.all, ["Hel", "lo"])
        XCTAssertEqual(response.message.text, "Hello")
        XCTAssertEqual(response.message.id, "m1")
        XCTAssertEqual(response.conversationId, "c1")
        XCTAssertEqual(response.credits, 1)
        let first = MockServer.sent[0]
        XCTAssertEqual(first.path, "/api/sdk/agents/agent/chat")
        XCTAssertEqual(first.headers["User-Agent"], "QwryAI-iOS-SDK/\(QwryClient.version)")
        XCTAssertEqual(first.headers["X-Device-Id"], "device-1")
        XCTAssertNil(first.headers["X-User-Token"])
        XCTAssertEqual(first.body, ["message": "Hi", "stream": true])
        try await client.send("More")
        XCTAssertEqual(MockServer.sent[1].body["conversationId"], "c1")
        await client.newConversation()
        let current = await client.currentConversationId
        XCTAssertNil(current)
    }

    func testRunsRegisteredToolsAndSendsTheirResults() async throws {
        let toolFinish = finish.replacingOccurrences(of: #""finishReason":"stop""#, with: #""finishReason":"tool-calls""#)
        MockServer.answers = [(200, sse(#"{"type":"tool-input-available","toolCallId":"t1","toolName":"get_cart","input":{"limit":2}}"#, toolFinish)),
                              (200, #"{"data":{"success":true}}"#),
                              (200, sse(#"{"type":"text-delta","id":"text_0","delta":"Two items"}"#, finish))]
        let client = client()
        await client.tool("get_cart") { input in ["items": input["limit"] ?? .null] }
        let response = try await client.send("What is in my cart?")
        XCTAssertEqual(response.message.text, "Two items")
        XCTAssertEqual(MockServer.sent[1].path, "/api/sdk/agents/agent/conversations/c1/tool-result")
        XCTAssertEqual(MockServer.sent[1].body, ["toolCallId": "t1", "output": ["items": 2]])
        XCTAssertEqual(MockServer.sent[2].body, ["conversationId": "c1", "stream": true])
    }

    func testAToolThatIsNotRegisteredOrThrowsReportsAnError() async throws {
        let toolFinish = finish.replacingOccurrences(of: #""finishReason":"stop""#, with: #""finishReason":"tool-calls""#)
        MockServer.answers = [(200, sse(#"{"type":"tool-input-available","toolCallId":"t1","toolName":"missing","input":{}}"#, toolFinish)), (200, "{}"), (200, sse(finish))]
        try await client().send("Go")
        XCTAssertEqual(MockServer.sent[1].body["output"], ["error": "No tool named missing is registered in the app"])
    }

    func testStopsWhenTheAgentKeepsCallingTools() async {
        let toolFinish = finish.replacingOccurrences(of: #""finishReason":"stop""#, with: #""finishReason":"tool-calls""#)
        let round = sse(#"{"type":"tool-input-available","toolCallId":"t1","toolName":"loop","input":{}}"#, toolFinish)
        MockServer.answers = [(200, round), (200, "{}"), (200, round), (200, "{}"), (200, round)]
        let client = client(maxSteps: 2)
        await client.tool("loop") { _ in .null }
        do { try await client.send("Go"); XCTFail("expected the loop limit") } catch { XCTAssertEqual(error as? QwryError, .toolLoopLimitExceeded) }
    }

    func testServerToolsAreNotRunOnTheDevice() async throws {
        MockServer.answers = [(200, sse(#"{"type":"tool-input-available","toolCallId":"t1","toolName":"stock","input":{"id":42}}"#, #"{"type":"tool-output-available","toolCallId":"t1","output":{"stock":53}}"#,
                                        #"{"type":"text-delta","id":"text_0","delta":"In stock"}"#, finish))]
        let response = try await client().send("Stock?")
        XCTAssertEqual(response.message.parts, [.toolCall(ToolCall(id: "t1", name: "stock", input: ["id": 42])), .toolResult(ToolResult(id: "t1", name: "stock", output: ["stock": 53])), .text("In stock")])
        XCTAssertEqual(MockServer.sent.count, 1)
    }

    func testNonStreamingAnswer() async throws {
        MockServer.answers = [(200, #"{"data":{"id":"m1","role":"assistant","parts":[{"type":"text","text":"Hello"}],"metadata":{"conversationId":"c1","userMessageId":"u1","userId":"user-1","finishReason":"stop","usage":{"credits":2}}}}"#)]
        let response = try await client().sendNonStreaming("Hi")
        XCTAssertEqual(response.message.text, "Hello")
        XCTAssertEqual(response.userId, "user-1")
        XCTAssertEqual(response.credits, 2)
        XCTAssertEqual(MockServer.sent[0].body["stream"], false)
    }

    func testServerErrorsKeepTheirCode() async {
        MockServer.answers = [(404, #"{"error":{"code":"AGENT_NOT_FOUND","message":"Agent not found"}}"#), (500, #"{"type":"error"}"#)]
        do { try await client().send("Hi"); XCTFail("expected an error") } catch {
            XCTAssertEqual(error as? QwryError, .api(status: 404, code: "AGENT_NOT_FOUND", message: "Agent not found", details: nil))
            XCTAssertEqual((error as? QwryError)?.isNotFound, true)
        }
        do { _ = try await client().listConversations(); XCTFail("expected an error") } catch {
            guard case .api(500, "INTERNAL_SERVER_ERROR", _, _) = error as? QwryError else { return XCTFail("\(error)") }
        }
    }

    func testAStreamErrorFailsTheSend() async {
        MockServer.answers = [(200, sse(#"{"type":"error","errorText":"Out of credits"}"#, finish.replacingOccurrences(of: #""finishReason":"stop""#, with: #""finishReason":"error""#)))]
        do { try await client().send("Hi"); XCTFail("expected an error") } catch {
            XCTAssertEqual(error as? QwryError, .api(status: 500, code: "CHAT_STREAMING_ERROR", message: "Out of credits", details: nil))
        }
    }

    func testIdentifyKeepsTheTokenAndLogoutDropsIt() async throws {
        MockServer.answers = [(200, #"{"data":{"userId":"user-1"}}"#), (200, #"{"data":[],"pagination":{"cursor":null,"hasMore":false,"total":0}}"#), (200, #"{"data":[],"pagination":{"cursor":null,"hasMore":false,"total":0}}"#)]
        let client = client()
        let userId = try await client.identify(token: "a.b.c")
        XCTAssertEqual(userId, "user-1")
        XCTAssertEqual(MockServer.sent[0].path, "/api/sdk/agents/agent/verify")
        XCTAssertEqual(MockServer.sent[0].body, ["token": "a.b.c"])
        XCTAssertEqual(tokens.token, "a.b.c")
        var state = await client.authState
        XCTAssertEqual(state, .identified(userId: "user-1"))
        _ = try await client.listConversations()
        XCTAssertEqual(MockServer.sent[1].headers["X-User-Token"], "a.b.c")
        await client.logout()
        state = await client.authState
        XCTAssertEqual(state, .anonymous)
        XCTAssertNil(tokens.token)
        _ = try await client.listConversations()
        XCTAssertNil(MockServer.sent[2].headers["X-User-Token"])
    }

    func testASavedTokenRestoresTheUserOnLaunch() async {
        tokens.token = "x." + Data(#"{"user_id":"user-9"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".y"
        let state = await client().authState
        XCTAssertEqual(state, .identified(userId: "user-9"))
    }

    func testHistoryPages() async throws {
        MockServer.answers = [(200, #"{"data":[{"id":"c1","title":"Hoodie","createdAt":1700000000,"updatedAt":1700000100,"userId":null,"status":"ongoing"}],"pagination":{"cursor":"next","hasMore":true,"total":3}}"#),
                              (200, #"{"data":[{"id":"u1","role":"user","parts":[{"type":"text","text":"Hi"}],"createdAt":1700000000},{"id":"m1","role":"assistant","parts":[{"type":"tool-call","toolCallId":"t","toolName":"stock","input":{}},{"type":"text","text":"Hello"}],"createdAt":1700000001,"feedback":"positive","metadata":{"score":0.9}}],"pagination":{"cursor":null,"hasMore":false,"total":2}}"#)]
        let client = client()
        let conversations = try await client.listConversations(limit: 1)
        XCTAssertEqual(conversations.items.first?.title, "Hoodie")
        XCTAssertEqual(conversations.items.first?.status, .ongoing)
        XCTAssertEqual(conversations.cursor, "next"); XCTAssertTrue(conversations.hasMore); XCTAssertEqual(conversations.total, 3)
        XCTAssertEqual(MockServer.sent[0].query, "limit=1")
        let messages = try await client.listMessages(conversationId: "c1", cursor: "abc")
        XCTAssertEqual(MockServer.sent[1].query, "limit=20&cursor=abc")
        XCTAssertEqual(messages.items.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.items[1].text, "Hello"); XCTAssertEqual(messages.items[1].feedback, .positive); XCTAssertEqual(messages.items[1].score, 0.9)
    }

    @MainActor func testConversationStateShowsTheExchange() async {
        MockServer.answers = [(200, sse(#"{"type":"text-delta","id":"text_0","delta":"Hello"}"#, finish)), (404, #"{"error":{"code":"AGENT_NOT_FOUND","message":"Agent not found"}}"#)]
        let chat = ConversationState(client: client())
        await chat.send("Hi")
        XCTAssertEqual(chat.messages.map(\.text), ["Hi", "Hello"])
        XCTAssertEqual(chat.messages.last?.id, "m1")
        XCTAssertEqual(chat.conversationId, "c1")
        XCTAssertFalse(chat.isSending)
        await chat.send("Again")
        XCTAssertEqual(chat.messages.map(\.text), ["Hi", "Hello", "Again"])
        XCTAssertEqual(chat.error?.isNotFound, true)
    }
}

final class Deltas: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []
    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}
