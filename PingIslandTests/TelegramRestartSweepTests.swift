import XCTest
@testable import Ping_Island

@MainActor
final class TelegramRestartSweepTests: XCTestCase {
    func testSweepEditsOrphanedMessagesAndKeepsActiveAttention() async throws {
        let stateStore = InMemoryTelegramStateStore(makeState())
        let client = FakeTelegramRestartSweepClient()
        let sweeper = TelegramRestartSweeper(
            messageRegistry: TelegramMessageRegistry(stateStore: stateStore),
            callbackRegistry: TelegramCallbackRegistry(stateStore: stateStore),
            client: client,
            rateLimitQueue: TelegramRateLimitQueue(minimumSpacing: 0)
        )
        let activeSession = SessionState(
            sessionId: "active-session",
            cwd: "/tmp/ping-island",
            projectName: "ping-island",
            phase: .waitingForApproval(PermissionContext(
                toolUseId: "active-tool",
                toolName: "Bash",
                toolInput: [:],
                receivedAt: Date(timeIntervalSince1970: 1_775_000_000)
            ))
        )

        await sweeper.sweep(activeSessions: [activeSession])

        XCTAssertEqual(client.editedMessages.map(\.messageId), [222])
        XCTAssertEqual(client.editedMessages.map(\.text), [
            TelegramL10n.string("Telegram.Message.RestartedConfirmInNotch")
        ])
        let state = try stateStore.load()
        XCTAssertEqual(Set(state.messages.keys), [
            InterventionKey.make(sessionId: "active-session", interventionId: "active-tool")
        ])
        XCTAssertEqual(Set(state.callbacks.keys), ["active-token"])
    }

    private func makeState() -> TelegramPersistentState {
        TelegramPersistentState(
            messages: [
                InterventionKey.make(sessionId: "active-session", interventionId: "active-tool"): .init(
                    chatId: 123,
                    messageId: 111,
                    sentAt: Date(timeIntervalSince1970: 1_775_000_000)
                ),
                InterventionKey.make(sessionId: "orphan-session", interventionId: "orphan-tool"): .init(
                    chatId: 123,
                    messageId: 222,
                    sentAt: Date(timeIntervalSince1970: 1_775_000_000)
                )
            ],
            callbacks: [
                "active-token": .init(
                    sessionId: "active-session",
                    interventionId: "active-tool",
                    action: .allowOnce,
                    issuedAt: Date(timeIntervalSince1970: 1_775_000_000)
                ),
                "orphan-token": .init(
                    sessionId: "orphan-session",
                    interventionId: "orphan-tool",
                    action: .deny,
                    issuedAt: Date(timeIntervalSince1970: 1_775_000_000)
                )
            ]
        )
    }
}

private final class FakeTelegramRestartSweepClient: TelegramMessagingClient {
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
