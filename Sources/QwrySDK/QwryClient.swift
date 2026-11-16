import Foundation

/// What to hear about while an answer is being written.
public struct SendHandlers: Sendable {
    /// A piece of the agent's text, as it arrives.
    public var onTextDelta: (@Sendable (String) -> Void)?
    /// The agent called a tool: one you registered, or one the server runs.
    public var onToolCall: (@Sendable (ToolCall) -> Void)?
    /// A tool finished.
    public var onToolResult: (@Sendable (ToolResult) -> Void)?
    public init() {}
}

/// Talks to one QwryAI agent. Create it once and keep it.
///
/// ```swift
/// let client = QwryClient(agentId: "…")
/// let response = try await client.send("Hello")
/// print(response.message.text)
/// ```
public actor QwryClient {
    public static let version = "0.1.0"
    public static let defaultBaseURL = URL(string: "https://www.qwryai.com/api/sdk")!

    public nonisolated let agentId: String
    /// Identifies this install. Anonymous conversations belong to it.
    public nonisolated let deviceId: String
    /// The conversation `send` continues. Nil until the first answer, and after `newConversation()`.
    public private(set) var currentConversationId: String?
    public private(set) var authState: AuthState = .anonymous
    public var currentUserId: String? { if case .identified(let userId) = authState { return userId }; return nil }

    private let root: URL
    private let session: URLSession
    private let maxToolLoopSteps: Int
    private let tokens: TokenStore
    private var token: String?
    private var tools: [String: @Sendable (JSONValue) async throws -> JSONValue] = [:]

    /// - Parameters:
    ///   - agentId: The agent's ID, from its iOS SDK page in the dashboard.
    ///   - baseURL: The SDK API to call. Change it only for a self-hosted or test server.
    ///   - maxToolLoopSteps: How many rounds of tool calls one `send` may make before it gives up.
    public init(agentId: String, baseURL: URL = QwryClient.defaultBaseURL, configuration: URLSessionConfiguration = .default, maxToolLoopSteps: Int = 10) {
        self.init(agentId: agentId, baseURL: baseURL, configuration: configuration, maxToolLoopSteps: maxToolLoopSteps,
                  tokens: KeychainTokenStore(agentId: agentId), deviceId: storedDeviceId(in: .standard))
    }

    init(agentId: String, baseURL: URL, configuration: URLSessionConfiguration, maxToolLoopSteps: Int, tokens: TokenStore, deviceId: String) {
        self.agentId = agentId
        self.deviceId = deviceId
        self.root = baseURL.appendingPathComponent("agents").appendingPathComponent(agentId)
        self.session = URLSession(configuration: configuration)
        self.maxToolLoopSteps = maxToolLoopSteps
        self.tokens = tokens
        self.token = tokens.read()
        if let token, let userId = userId(inToken: token) { authState = .identified(userId: userId) }
    }

    // MARK: Chat

    /// Sends a message and returns the agent's answer once it is complete, calling `configure`'s handlers as it streams.
    /// Continues `conversationId`, or the current conversation, or starts a new one.
    @discardableResult
    public func send(_ text: String, conversationId: String? = nil, configure: @Sendable (inout SendHandlers) -> Void = { _ in }) async throws -> ChatResponse {
        var handlers = SendHandlers(); configure(&handlers)
        return try await converse(path: "chat", body: ["message": .string(text)], conversationId: conversationId ?? currentConversationId, stream: true, handlers: handlers)
    }

    /// Like `send`, but the answer arrives in one response instead of a stream.
    @discardableResult
    public func sendNonStreaming(_ text: String, conversationId: String? = nil) async throws -> ChatResponse {
        try await converse(path: "chat", body: ["message": .string(text)], conversationId: conversationId ?? currentConversationId, stream: false, handlers: SendHandlers())
    }

    /// Asks the agent to answer again in place of `messageId`. That answer and everything after it are replaced.
    @discardableResult
    public func retry(conversationId: String, messageId: String, configure: @Sendable (inout SendHandlers) -> Void = { _ in }) async throws -> ChatResponse {
        var handlers = SendHandlers(); configure(&handlers)
        return try await converse(path: "conversations/\(conversationId)/retry", body: ["messageId": .string(messageId)], conversationId: nil, stream: true, handlers: handlers)
    }

    /// Forgets the current conversation. The next `send` starts a new one.
    public func newConversation() { currentConversationId = nil }

    // MARK: Tools

    /// Runs `handler` on this device when the agent calls the client-side action named `name`.
    /// What it returns goes back to the agent; if it throws, the agent is told the error.
    public func tool(_ name: String, handler: @escaping @Sendable (JSONValue) async throws -> JSONValue) { tools[name] = handler }
    public func removeTool(_ name: String) { tools[name] = nil }

    // MARK: History

    /// This user's conversations (this device's while anonymous), most recently active first.
    public func listConversations(cursor: String? = nil, limit: Int = 20) async throws -> Page<Conversation> {
        try await get("conversations", cursor: cursor, limit: limit)
    }

    /// A page of a conversation, oldest message first. `cursor` reaches further back.
    public func listMessages(conversationId: String, cursor: String? = nil, limit: Int = 20) async throws -> Page<Message> {
        try await get("conversations/\(conversationId)/messages", cursor: cursor, limit: limit)
    }

    // MARK: Identity

    /// Signs the user in with a JWT your server made with the agent's identity verification secret.
    /// Conversations this device started anonymously move to the user.
    @discardableResult
    public func identify(token: String) async throws -> String {
        struct Verified: Decodable { struct Body: Decodable { let userId: String }; let data: Body }
        var request = makeRequest("verify", method: "POST")
        request.httpBody = try JSONEncoder().encode(["token": token])
        let verified = try decode(Verified.self, from: try await data(for: request))
        self.token = token
        tokens.write(token)
        authState = .identified(userId: verified.data.userId)
        currentConversationId = nil
        return verified.data.userId
    }

    /// Signs the user out. The SDK goes back to this device's own conversations.
    public func logout() {
        token = nil
        tokens.write(nil)
        authState = .anonymous
        currentConversationId = nil
    }

    // MARK: Requests

    private func makeRequest(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: root.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("QwryAI-iOS-SDK/\(QwryClient.version)", forHTTPHeaderField: "User-Agent")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        if let token { request.setValue(token, forHTTPHeaderField: "X-User-Token") }
        if method == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func get<Item>(_ path: String, cursor: String?, limit: Int) async throws -> Page<Item> {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try decode(Page<Item>.self, from: try await data(for: makeRequest(path, query: query)))
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw failure(error) }
        try check(response, body: data)
        return data
    }

    /// A cancelled task is not a failure to report: it stays a `CancellationError`.
    private func failure(_ error: Error) -> Error {
        (error as? URLError)?.code == .cancelled || error is CancellationError ? CancellationError() : QwryError.network(error.localizedDescription)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw QwryError.invalidResponse }
    }

    private func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw QwryError.invalidResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        struct Failure: Decodable { struct Body: Decodable { let code: String; let message: String; let details: [String: String]? }; let error: Body }
        guard let failure = try? JSONDecoder().decode(Failure.self, from: body) else {
            throw QwryError.api(status: http.statusCode, code: "INTERNAL_SERVER_ERROR", message: "Something went wrong, please try again", details: nil)
        }
        throw QwryError.api(status: http.statusCode, code: failure.error.code, message: failure.error.message, details: failure.error.details)
    }

    // MARK: Turns

    /// One request and its answer, then the tool rounds the agent asks for.
    private func converse(path: String, body: [String: JSONValue], conversationId: String?, stream: Bool, handlers: SendHandlers) async throws -> ChatResponse {
        var body = body
        if let conversationId { body["conversationId"] = .string(conversationId) }
        var turn = try await perform(path: path, body: body, stream: stream, handlers: handlers)
        var steps = 0
        while turn.response.finishReason == .toolCalls, !turn.pending.isEmpty {
            steps += 1
            guard steps <= maxToolLoopSteps else { throw QwryError.toolLoopLimitExceeded }
            let conversation = turn.response.conversationId
            for call in turn.pending {
                let output = await run(call)
                handlers.onToolResult?(ToolResult(id: call.id, name: call.name, output: output))
                try await submit(output, for: call, conversationId: conversation)
            }
            // No message: the agent carries on from the tool results.
            turn = try await perform(path: "chat", body: ["conversationId": .string(conversation)], stream: stream, handlers: handlers)
        }
        return turn.response
    }

    private func run(_ call: ToolCall) async -> JSONValue {
        guard let handler = tools[call.name] else { return ["error": .string("No tool named \(call.name) is registered in the app")] }
        do { return try await handler(call.input) } catch { return ["error": .string(error.localizedDescription)] }
    }

    /// A lost tool result would leave the conversation waiting, so a failed submit is tried again.
    private func submit(_ output: JSONValue, for call: ToolCall, conversationId: String) async throws {
        var request = makeRequest("conversations/\(conversationId)/tool-result", method: "POST")
        request.httpBody = try JSONEncoder().encode(["toolCallId": JSONValue.string(call.id), "output": output])
        var delay: UInt64 = 300_000_000
        for attempt in 0...3 {
            do { _ = try await data(for: request); return } catch let error as QwryError {
                guard case .network = error, attempt < 3 else { throw error }
                try await Task.sleep(nanoseconds: delay); delay *= 2
            }
        }
    }

    fileprivate struct TurnResult { var response: ChatResponse; var pending: [ToolCall] }
    private typealias Turn = TurnResult

    private func perform(path: String, body: [String: JSONValue], stream: Bool, handlers: SendHandlers) async throws -> Turn {
        var request = makeRequest(path, method: "POST")
        request.httpBody = try JSONEncoder().encode(body.merging(["stream": .bool(stream)]) { $1 })
        let turn = stream ? try await streamed(request, handlers: handlers) : try await whole(request, handlers: handlers)
        currentConversationId = turn.response.conversationId
        return turn
    }

    private func whole(_ request: URLRequest, handlers: SendHandlers) async throws -> Turn {
        struct Envelope: Decodable {
            struct Body: Decodable { let id: String; let parts: [MessagePart]; let metadata: Metadata }
            struct Metadata: Decodable { let conversationId: String; let userMessageId: String?; let userId: String?; let finishReason: String?; let usage: Usage? }
            struct Usage: Decodable { let credits: Double? }
            let data: Body
        }
        let body = try decode(Envelope.self, from: try await data(for: request)).data
        var accumulator = Accumulator(handlers: handlers)
        for part in body.parts {
            switch part {
            case .text(let text): accumulator.text(text, startsPart: true)
            case .toolCall(let call): accumulator.call(call)
            case .toolResult(let result): accumulator.result(id: result.id, output: result.output)
            }
        }
        return accumulator.turn(messageId: body.id, conversationId: body.metadata.conversationId, userMessageId: body.metadata.userMessageId,
                                userId: body.metadata.userId, finishReason: body.metadata.finishReason, credits: body.metadata.usage?.credits)
    }

    private func streamed(_ request: URLRequest, handlers: SendHandlers) async throws -> Turn {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(for: request) } catch { throw failure(error) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            try check(response, body: body)
        }
        var accumulator = Accumulator(handlers: handlers)
        var messageId: String?
        var finish: StreamEvent?
        var failure: String?
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let event = try? JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8)) else { continue }
                switch event.type {
                case "start": messageId = event.messageId
                case "text-start": accumulator.text("", startsPart: true)
                case "text-delta": accumulator.text(event.delta ?? "", startsPart: false)
                case "tool-input-available":
                    if let id = event.toolCallId { accumulator.call(ToolCall(id: id, name: event.toolName ?? "", input: event.input ?? .null)) }
                case "tool-output-available":
                    if let id = event.toolCallId { accumulator.result(id: id, output: event.output ?? .null) }
                case "tool-output-error":
                    if let id = event.toolCallId { accumulator.result(id: id, output: ["error": .string(event.errorText ?? "The tool failed")]) }
                case "error": failure = event.errorText ?? "Something went wrong, please try again"
                case "finish": finish = event
                default: break
                }
            }
        } catch { throw self.failure(error) }
        if let failure { throw QwryError.api(status: 500, code: "CHAT_STREAMING_ERROR", message: failure, details: nil) }
        guard let finish, let metadata = finish.messageMetadata, let conversationId = metadata.conversationId else { throw QwryError.invalidResponse }
        return accumulator.turn(messageId: metadata.messageId ?? messageId ?? UUID().uuidString, conversationId: conversationId, userMessageId: metadata.userMessageId,
                                userId: metadata.userId, finishReason: finish.finishReason, credits: metadata.usage?.credits)
    }
}

/// One `data:` line of the answer stream.
private struct StreamEvent: Decodable {
    struct Metadata: Decodable { let conversationId: String?; let messageId: String?; let userMessageId: String?; let userId: String?; let usage: Usage? }
    struct Usage: Decodable { let credits: Double? }
    let type: String
    let messageId: String?
    let delta: String?
    let toolCallId: String?
    let toolName: String?
    let input: JSONValue?
    let output: JSONValue?
    let errorText: String?
    let finishReason: String?
    let messageMetadata: Metadata?
}

/// Builds the answer's parts as they arrive and tells the app's handlers.
private struct Accumulator {
    let handlers: SendHandlers
    private var parts: [MessagePart] = []
    private var calls: [ToolCall] = []
    private var answered: Set<String> = []
    private var textOpen = false

    init(handlers: SendHandlers) { self.handlers = handlers }

    mutating func text(_ text: String, startsPart: Bool) {
        if startsPart || !textOpen { parts.append(.text("")); textOpen = true }
        guard !text.isEmpty, case .text(let current) = parts[parts.count - 1] else { return }
        parts[parts.count - 1] = .text(current + text)
        handlers.onTextDelta?(text)
    }

    mutating func call(_ call: ToolCall) {
        textOpen = false
        calls.append(call)
        parts.append(.toolCall(call))
        handlers.onToolCall?(call)
    }

    mutating func result(id: String, output: JSONValue) {
        textOpen = false
        answered.insert(id)
        let result = ToolResult(id: id, name: calls.first { $0.id == id }?.name ?? "", output: output)
        parts.append(.toolResult(result))
        handlers.onToolResult?(result)
    }

    func turn(messageId: String, conversationId: String, userMessageId: String?, userId: String?, finishReason: String?, credits: Double?) -> QwryClient.TurnResult {
        let kept = parts.filter { if case .text(let text) = $0 { return !text.isEmpty }; return true }
        let response = ChatResponse(message: Message(id: messageId, role: .assistant, parts: kept, createdAt: Date()), conversationId: conversationId, userMessageId: userMessageId,
                                    userId: userId, finishReason: ChatResponse.FinishReason(rawValue: finishReason ?? "stop") ?? .stop, credits: credits ?? 0)
        return QwryClient.TurnResult(response: response, pending: calls.filter { !answered.contains($0.id) })
    }
}
