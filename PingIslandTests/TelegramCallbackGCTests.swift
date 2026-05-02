import XCTest
@testable import Ping_Island

@MainActor
final class TelegramCallbackGCTests: XCTestCase {
    func testCollectEditsExpiredMessagesAndKeepsFreshCallbacks() async throws {
        let stateStore = InMemoryTelegramStateStore(makeState())
        let client = FakeTelegramCallbackGCClient()
        let collector = TelegramCallbackGarbageCollector(
            messageRegistry: TelegramMessageRegistry(stateStore: stateStore),
            callbackRegistry: TelegramCallbackRegistry(stateStore: stateStore),
            client: client,
            rateLimitQueue: TelegramRateLimitQueue(minimumSpacing: 0)
        )

        await collector.collect(now: Date(timeIntervalSince1970: 1_775_000_000))

        XCTAssertEqual(client.editedMessages.map(\.messageId), [111])
        XCTAssertEqual(client.editedMessages.map(\.text), [
            TelegramL10n.string("Telegram.Message.Expired")
        ])
        let state = try stateStore.load()
        XCTAssertEqual(Set(state.messages.keys), [
            InterventionKey.make(sessionId: "fresh-session", interventionId: "fresh-tool")
        ])
        XCTAssertEqual(Set(state.callbacks.keys), ["fresh-token"])
    }

    private func makeState() -> TelegramPersistentState {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        return TelegramPersistentState(
            messages: [
                InterventionKey.make(sessionId: "expired-session", interventionId: "expired-tool"): .init(
                    chatId: 123,
                    messageId: 111,
                    sentAt: now.addingTimeInterval(-25 * 60 * 60)
                ),
                InterventionKey.make(sessionId: "fresh-session", interventionId: "fresh-tool"): .init(
                    chatId: 123,
                    messageId: 222,
                    sentAt: now.addingTimeInterval(-60)
                )
            ],
            callbacks: [
                "expired-allow": .init(
                    sessionId: "expired-session",
                    interventionId: "expired-tool",
                    action: .allowOnce,
                    issuedAt: now.addingTimeInterval(-25 * 60 * 60)
                ),
                "expired-deny": .init(
                    sessionId: "expired-session",
                    interventionId: "expired-tool",
                    action: .deny,
                    issuedAt: now.addingTimeInterval(-25 * 60 * 60)
                ),
                "fresh-token": .init(
                    sessionId: "fresh-session",
                    interventionId: "fresh-tool",
                    action: .allowOnce,
                    issuedAt: now.addingTimeInterval(-60)
                )
            ]
        )
    }
}

private final class FakeTelegramCallbackGCClient: TelegramMessagingClient {
    struct EditedMessage {
        let chatId: Int64
        let messageId: Int64
        let text: String
    }

    private(set) var editedMessages: [EditedMessage] = []

    func sendMessage(
        chatId: Int64,
        text: String,
        replyMarkup: TelegramInlineKeyboardMarkup?,
        disableNotification: Bool
    ) async -> Result<TelegramMessage, TelegramAPIError> {
        .failure(.transport("not implemented"))
    }

    func editMessageText(
        chatId: Int64,
        messageId: Int64,
        text: String,
        replyMarkup: TelegramInlineKeyboardMarkup?
    ) async -> Result<TelegramMessage, TelegramAPIError> {
        editedMessages.append(.init(chatId: chatId, messageId: messageId, text: text))
        return .success(.init(
            messageId: messageId,
            date: 1_775_000_000,
            chat: .init(id: chatId, type: "private"),
            text: text
        ))
    }
}
