import Foundation
import Observation

/// One conversation, ready to show in SwiftUI: its messages, with the agent's answer growing as it streams.
///
/// ```swift
/// @State private var chat = ConversationState(client: client)
/// ForEach(chat.messages) { Text($0.text) }
/// Button("Send") { Task { await chat.send(draft) } }
/// ```
@MainActor
@Observable
public final class ConversationState {
    public private(set) var messages: [Message] = []
    /// True from `send` or `retry` until the answer is complete.
    public private(set) var isSending = false
    /// Why the last `send`, `retry` or history load failed. Cleared by the next one.
    public private(set) var error: QwryError?
    public private(set) var conversationId: String?
    /// True while older messages remain to load with `loadEarlier()`.
    public private(set) var hasEarlier = false

    private let client: QwryClient
    private var cursor: String?

    /// - Parameter conversationId: A conversation to continue. Leave nil to start a new one on the first `send`.
    public init(client: QwryClient, conversationId: String? = nil) {
        self.client = client
        self.conversationId = conversationId
    }

    public func send(_ text: String) async {
        messages.append(Message(id: "local-\(UUID().uuidString)", role: .user, parts: [.text(text)], createdAt: Date()))
        let (client, conversationId) = (client, conversationId)
        await answer { onDelta in
            // A new conversation must not continue whichever one the client used last.
            if conversationId == nil { await client.newConversation() }
            return try await client.send(text, conversationId: conversationId) { $0.onTextDelta = onDelta }
        }
    }

    /// Asks for a new answer in place of `messageId`. That answer and everything after it are replaced.
    public func retry(messageId: String) async {
        guard let conversationId, let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages.removeSubrange(index...)
        let client = client
        await answer { onDelta in try await client.retry(conversationId: conversationId, messageId: messageId) { $0.onTextDelta = onDelta } }
    }

    /// Loads the latest page of the conversation, replacing what is shown.
    public func load() async {
        guard let conversationId else { return }
        await page(conversationId, cursor: nil) { self.messages = $0 }
    }

    /// Loads the page before the oldest message shown.
    public func loadEarlier() async {
        guard let conversationId, hasEarlier, let cursor else { return }
        await page(conversationId, cursor: cursor) { self.messages.insert(contentsOf: $0, at: 0) }
    }

    private func page(_ conversationId: String, cursor: String?, apply: ([Message]) -> Void) async {
        error = nil
        do {
            let page = try await client.listMessages(conversationId: conversationId, cursor: cursor)
            apply(page.items)
            self.cursor = page.cursor
            hasEarlier = page.hasMore
        } catch is CancellationError {
        } catch { self.error = error as? QwryError ?? .network(error.localizedDescription) }
    }

    private func answer(_ request: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> ChatResponse) async {
        isSending = true
        error = nil
        let draftId = "pending-\(UUID().uuidString)"
        messages.append(Message(id: draftId, role: .assistant, parts: [.text("")], createdAt: Date()))
        let (deltas, continuation) = AsyncStream<String>.makeStream()
        let writer = Task {
            for await delta in deltas {
                guard let index = messages.firstIndex(where: { $0.id == draftId }) else { continue }
                messages[index].parts = [.text(messages[index].text + delta)]
            }
        }
        do {
            let response = try await request { continuation.yield($0) }
            continuation.finish(); await writer.value
            if let index = messages.firstIndex(where: { $0.id == draftId }) { messages[index] = response.message }
            conversationId = response.conversationId
        } catch {
            continuation.finish(); await writer.value
            messages.removeAll { $0.id == draftId }
            if !(error is CancellationError) { self.error = error as? QwryError ?? .network(error.localizedDescription) }
        }
        isSending = false
    }
}

/// The user's conversations, ready to show in SwiftUI.
@MainActor
@Observable
public final class ConversationListState {
    public private(set) var conversations: [Conversation] = []
    public private(set) var hasMore = false
    public private(set) var error: QwryError?

    private let client: QwryClient
    private var cursor: String?

    public init(client: QwryClient) { self.client = client }

    /// Loads the most recently active conversations, replacing what is shown.
    public func load() async { await page(cursor: nil) { self.conversations = $0 } }

    public func loadMore() async {
        guard hasMore, let cursor else { return }
        await page(cursor: cursor) { self.conversations.append(contentsOf: $0) }
    }

    private func page(cursor: String?, apply: ([Conversation]) -> Void) async {
        error = nil
        do {
            let page = try await client.listConversations(cursor: cursor)
            apply(page.items)
            self.cursor = page.cursor
            hasMore = page.hasMore
        } catch is CancellationError {
        } catch { self.error = error as? QwryError ?? .network(error.localizedDescription) }
    }
}
