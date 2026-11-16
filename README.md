# QwryAI iOS SDK

Put your QwryAI agent inside an iOS app. The SDK has no UI of its own: it sends messages, streams answers, runs your client-side actions and keeps conversation history, and you draw the chat.

Requires iOS 17+ / macOS 14+ and Swift 6.0+. No dependencies.

## Before you start

In the QwryAI dashboard open your agent, go to **Channels → iOS SDK**, and switch **Visibility** on in the Overview tab. The Setup tab shows your agent ID.

## Install

In Xcode: **File → Add Package Dependencies…** and enter the repository URL. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/qwryai/qwryai-ios-sdk.git", from: "0.1.0")
]
```

## Quick start

```swift
import QwrySDK

let client = QwryClient(agentId: "YOUR_AGENT_ID")

let response = try await client.send("Hello")
print(response.message.text)
```

Create one client and keep it. The next `send` continues the same conversation; call `newConversation()` to start another.

## Streaming

`send` streams. Give it handlers to show the answer as it is written:

```swift
try await client.send("Where is my order?") { handlers in
    handlers.onTextDelta = { piece in print(piece, terminator: "") }
    handlers.onToolCall = { call in print("Calling \(call.name)") }
}
```

`sendNonStreaming` waits for the whole answer instead.

## SwiftUI

`ConversationState` holds one conversation's messages and updates them as the answer streams:

```swift
struct ChatView: View {
    @State private var chat: ConversationState
    @State private var draft = ""

    init(client: QwryClient) { _chat = State(initialValue: ConversationState(client: client)) }

    var body: some View {
        List(chat.messages) { message in Text(message.text) }
        TextField("Message", text: $draft)
            .onSubmit { let text = draft; draft = ""; Task { await chat.send(text) } }
            .disabled(chat.isSending)
    }
}
```

`ConversationListState` does the same for the list of conversations. `chat.error` holds the last failure.

## Client-side actions

When an action in your agent is set to run on the client, register a tool with the same name. The SDK runs it when the agent calls it, sends the result back, and carries on with the answer:

```swift
await client.tool("get_cart") { input in
    ["items": .array(cart.items.map { .string($0.name) })]
}
```

Switch the action on for the iOS SDK in the channel's **Actions** tab. A tool result may be up to 20 KB. If your tool throws, the agent is told the error.

## Identify your users

Until you identify a user, conversations belong to the device. To carry them across devices, sign a JWT on your server with the agent's identity verification secret (HS256, with a `user_id` or `sub` claim) and pass it in:

```swift
try await client.identify(token: tokenFromYourServer)
// later
await client.logout()
```

Conversations the device started before signing in move to the user. The token is kept in the Keychain, so the user stays signed in between launches.

## History

```swift
let conversations = try await client.listConversations()
let page = try await client.listMessages(conversationId: conversations.items[0].id)
if page.hasMore { let earlier = try await client.listMessages(conversationId: id, cursor: page.cursor) }
```

## Retry an answer

```swift
try await client.retry(conversationId: id, messageId: assistantMessageId)
```

## Errors

Everything throws `QwryError`:

| Case | Meaning |
| --- | --- |
| `.api(status, code, message, details)` | The server refused the request. `code` is stable. |
| `.network(message)` | The request never got an answer. |
| `.invalidResponse` | The server answered with something the SDK could not read. |
| `.toolLoopLimitExceeded` | The agent kept calling tools past `maxToolLoopSteps` (10 by default). |

Common codes: `AGENT_NOT_FOUND` (wrong agent ID, or the iOS SDK channel is switched off), `AUTH_INVALID_JWT`, `AUTH_OWNERSHIP_MISMATCH`, `RATE_LIMIT_TOO_MANY_REQUESTS`, `CHAT_CREDITS_EXHAUSTED`. `error.isRateLimited`, `isNotFound` and `isCreditsExhausted` cover the usual checks.

## License

MIT
