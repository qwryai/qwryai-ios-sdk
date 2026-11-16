import Foundation

/// One piece of a message: text the agent wrote, a tool it called, or what that tool returned.
public enum MessagePart: Sendable, Equatable, Codable {
    case text(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)

    private enum CodingKeys: String, CodingKey { case type, text, toolCallId, toolName, input, output }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "tool-call":
            self = .toolCall(ToolCall(id: try container.decode(String.self, forKey: .toolCallId), name: try container.decode(String.self, forKey: .toolName),
                                      input: try container.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null))
        case "tool-result":
            self = .toolResult(ToolResult(id: try container.decode(String.self, forKey: .toolCallId), name: try container.decodeIfPresent(String.self, forKey: .toolName) ?? "",
                                          output: try container.decodeIfPresent(JSONValue.self, forKey: .output) ?? .null))
        default:
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type); try container.encode(text, forKey: .text)
        case .toolCall(let call):
            try container.encode("tool-call", forKey: .type); try container.encode(call.id, forKey: .toolCallId)
            try container.encode(call.name, forKey: .toolName); try container.encode(call.input, forKey: .input)
        case .toolResult(let result):
            try container.encode("tool-result", forKey: .type); try container.encode(result.id, forKey: .toolCallId)
            try container.encode(result.name, forKey: .toolName); try container.encode(result.output, forKey: .output)
        }
    }
}

/// A tool the agent asked for. Tools registered with `QwryClient.tool` run on the device.
public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let input: JSONValue
    public init(id: String, name: String, input: JSONValue) { self.id = id; self.name = name; self.input = input }
}

public struct ToolResult: Sendable, Equatable {
    public let id: String
    public let name: String
    public let output: JSONValue
    public init(id: String, name: String, output: JSONValue) { self.id = id; self.name = name; self.output = output }
}

public struct Message: Sendable, Equatable, Identifiable, Decodable {
    public enum Role: String, Sendable, Codable { case user, assistant }
    public enum Feedback: String, Sendable, Codable { case positive, negative }

    public let id: String
    public let role: Role
    public var parts: [MessagePart]
    public let createdAt: Date?
    public let feedback: Feedback?
    /// The agent's confidence in this answer, when it reported one.
    public let score: Double?

    /// The message's text parts joined together.
    public var text: String { parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined() }

    public init(id: String, role: Role, parts: [MessagePart], createdAt: Date? = nil, feedback: Feedback? = nil, score: Double? = nil) {
        self.id = id; self.role = role; self.parts = parts; self.createdAt = createdAt; self.feedback = feedback; self.score = score
    }

    private enum CodingKeys: String, CodingKey { case id, role, parts, createdAt, feedback, metadata }
    private struct Metadata: Decodable { let score: Double? }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        parts = try container.decodeIfPresent([MessagePart].self, forKey: .parts) ?? []
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt).map(Date.init(timeIntervalSince1970:))
        feedback = try container.decodeIfPresent(Feedback.self, forKey: .feedback)
        score = try? container.decodeIfPresent(Metadata.self, forKey: .metadata)?.score
    }
}

/// The agent's answer to one `send` or `retry`.
public struct ChatResponse: Sendable, Equatable {
    public enum FinishReason: String, Sendable { case stop, error, toolCalls = "tool-calls" }

    public let message: Message
    public let conversationId: String
    /// The ID the server gave the message you sent.
    public let userMessageId: String?
    /// The identified user, or nil while anonymous.
    public let userId: String?
    public let finishReason: FinishReason
    /// Message credits this answer used.
    public let credits: Double
}

public struct Conversation: Sendable, Equatable, Identifiable, Decodable {
    public enum Status: String, Sendable, Codable { case ongoing, ended, takenOver = "taken_over" }

    public let id: String
    public let title: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let userId: String?
    public let status: Status

    private enum CodingKeys: String, CodingKey { case id, title, createdAt, updatedAt, userId, status }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        createdAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .createdAt))
        updatedAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .updatedAt))
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        status = try container.decode(Status.self, forKey: .status)
    }
}

/// One page of a list. Pass `cursor` back to get the next page.
public struct Page<Item: Sendable & Decodable>: Sendable, Decodable {
    public let items: [Item]
    public let cursor: String?
    public let hasMore: Bool
    public let total: Int

    private enum CodingKeys: String, CodingKey { case data, pagination }
    private struct Pagination: Decodable { let cursor: String?; let hasMore: Bool; let total: Int }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([Item].self, forKey: .data)
        let pagination = try container.decode(Pagination.self, forKey: .pagination)
        cursor = pagination.cursor; hasMore = pagination.hasMore; total = pagination.total
    }
}

/// Who the SDK is talking as.
public enum AuthState: Sendable, Equatable {
    /// Conversations belong to this device.
    case anonymous
    /// Conversations belong to this user, on every device they sign in on.
    case identified(userId: String)
}

public enum QwryError: Error, Sendable, Equatable {
    /// The server refused the request. `code` is stable, e.g. `AGENT_NOT_FOUND` or `RATE_LIMIT_TOO_MANY_REQUESTS`.
    case api(status: Int, code: String, message: String, details: [String: String]?)
    /// The request never got an answer.
    case network(String)
    /// The server answered with something the SDK could not read.
    case invalidResponse
    /// The agent kept calling tools past `maxToolLoopSteps`.
    case toolLoopLimitExceeded

    public var isRateLimited: Bool { if case .api(429, _, _, _) = self { return true }; return false }
    public var isNotFound: Bool { if case .api(404, _, _, _) = self { return true }; return false }
    public var isCreditsExhausted: Bool { if case .api(402, _, _, _) = self { return true }; return false }
}

extension QwryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .api(_, _, let message, _): message
        case .network(let message): message
        case .invalidResponse: "The server sent a response the SDK could not read."
        case .toolLoopLimitExceeded: "The agent called too many tools in a row."
        }
    }
}
