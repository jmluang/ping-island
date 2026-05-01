import XCTest
@testable import Ping_Island

@MainActor
final class TelegramOutboundObserverTests: XCTestCase {
    func testProcessSnapshotSendsNewApprovalAndPersistsRegistries() async throws {
        let client = FakeTelegramMessagingClient()
        let stateStore = InMemoryTelegramStateStore()
        let observer = makeObserver(client: client, stateStore: stateStore)
        let session = makeSession(
            phase: .waitingForApproval(makePermission(toolUseId: "tool-1"))
        )

        await observer.processSnapshot([session])

        XCTAssertEqual(client.sentMessages.count, 1)
        XCTAssertEqual(client.sentMessages.first?.chatId, 123)
        XCTAssertEqual(client.sentMessages.first?.text.contains("Tool: Bash"), true)
        XCTAssertEqual(client.sentMessages.first?.replyMarkup?.inlineKeyboard.flatMap { $0 }.map(\.callbackData), [
            "v1|tok1|allow_once",
            "v1|tok2|deny"
        ])

        let state = try stateStore.load()
        XCTAssertEqual(state.messages[InterventionKey.make(sessionId: "session-1", interventionId: "tool-1")]?.messageId, 9001)
        XCTAssertEqual(state.callbacks["tok1"]?.action, .allowOnce)
        XCTAssertEqual(state.callbacks["tok2"]?.action, .deny)
    }

    func testProcessSnapshotDoesNotDuplicateExistingAttentionKey() async {
        let client = FakeTelegramMessagingClient()
        let observer = makeObserver(client: client)
        let session = makeSession(phase: .waitingForApproval(makePermission(toolUseId: "tool-1")))

        await observer.processSnapshot([session])
        await observer.processSnapshot([session])

        XCTAssertEqual(client.sentMessages.count, 1)
    }

    func testRemovedAttentionWithoutRecentResponseEditsWithdrawnAndDropsRegistries() async throws {
        let client = FakeTelegramMessagingClient()
        let stateStore = InMemoryTelegramStateStore()
        let observer = makeObserver(client: client, stateStore: stateStore)
        let session = makeSession(phase: .waitingForApproval(makePermission(toolUseId: "tool-1")))

        await observer.processSnapshot([session])
        await observer.processSnapshot([])

        XCTAssertEqual(client.editedMessages.count, 1)
        XCTAssertEqual(client.editedMessages.first?.text, "⏱ Request withdrawn")
        let state = try stateStore.load()
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.callbacks.isEmpty)
    }

    func testRemovedAttentionWithRecentResponseSkipsWithdrawnEditButDropsRegistries() async throws {
        let client = FakeTelegramMessagingClient()
        let stateStore = InMemoryTelegramStateStore()
        let observer = makeObserver(client: client, stateStore: stateStore)
        let session = makeSession(phase: .waitingForApproval(makePermission(toolUseId: "tool-1")))

        await observer.processSnapshot([session])
        observer.recordResponse(.init(
            sessionId: "session-1",
            interventionId: "tool-1",
            decision: .approveOnce,
            source: .mac,
            timestamp: Date(timeIntervalSince1970: 1_775_000_000)
        ))
        await observer.processSnapshot([])

        XCTAssertTrue(client.editedMessages.isEmpty)
        let state = try stateStore.load()
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.callbacks.isEmpty)
    }

    private func makeObserver(
        client: FakeTelegramMessagingClient,
        stateStore: InMemoryTelegramStateStore = InMemoryTelegramStateStore()
    ) -> TelegramOutboundObserver {
        TelegramOutboundObserver(
            chatId: 123,
            client: client,
            messageRegistry: TelegramMessageRegistry(stateStore: stateStore),
            callbackRegistry: TelegramCallbackRegistry(stateStore: stateStore),
            rateLimitQueue: TelegramRateLimitQueue(minimumSpacing: 0),
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            tokenProvider: SequentialTelegramTokenProvider().nextToken
        )
    }

    private func makeSession(
        phase: SessionPhase
    ) -> SessionState {
        SessionState(
            sessionId: "session-1",
            cwd: "/tmp/ping-island",
            projectName: "ping-island",
            provider: .claude,
            phase: phase
        )
    }

    private func makePermission(
        toolUseId: String,
        toolName: String = "Bash"
    ) -> PermissionContext {
        PermissionContext(
            toolUseId: toolUseId,
            toolName: toolName,
            toolInput: ["command": AnyCodable("npm test")],
            receivedAt: Date(timeIntervalSince1970: 1_775_000_000)
        )
    }
}

private final class FakeTelegramMessagingClient: TelegramMessagingClient {
    struct SentMessage {
        let chatId: Int64
        let text: String
        let replyMarkup: TelegramInlineKeyboardMarkup?
    }

    struct EditedMessage {
        let chatId: Int64
        let messageId: Int64
        let text: String
        let replyMarkup: TelegramInlineKeyboardMarkup?
    }

    private(set) var sentMessages: [SentMessage] = []
    private(set) var editedMessages: [EditedMessage] = []

    func sendMessage(
        chatId: Int64,
        text: String,
        replyMarkup: TelegramInlineKeyboardMarkup?,
        disableNotification: Bool
    ) async -> Result<TelegramMessage, TelegramAPIError> {
        sentMessages.append(.init(chatId: chatId, text: text, replyMarkup: replyMarkup))
        return .success(.init(
            messageId: 9000 + Int64(sentMessages.count),
            date: 1_775_000_000,
            chat: .init(id: chatId, type: "private"),
            text: text
        ))
    }

    func editMessageText(
        chatId: Int64,
        messageId: Int64,
        text: String,
        replyMarkup: TelegramInlineKeyboardMarkup?
    ) async -> Result<TelegramMessage, TelegramAPIError> {
        editedMessages.append(.init(
            chatId: chatId,
            messageId: messageId,
            text: text,
            replyMarkup: replyMarkup
        ))
        return .success(.init(
            messageId: messageId,
            date: 1_775_000_000,
            chat: .init(id: chatId, type: "private"),
            text: text
        ))
    }
}

private final class SequentialTelegramTokenProvider {
    private var index = 0

    func nextToken(_ action: TelegramPersistentState.CallbackResolution.Action) -> String {
        index += 1
        return "tok\(index)"
    }
}
