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

    func testProcessSnapshotSuppressesApprovalWhenPermissionEventsAreDisabled() async {
        let client = FakeTelegramMessagingClient()
        let observer = makeObserver(client: client, categoryEnabled: { category in
            category != .permission
        })
        let session = makeSession(phase: .waitingForApproval(makePermission(toolUseId: "tool-1")))

        await observer.processSnapshot([session])

        XCTAssertTrue(client.sentMessages.isEmpty)
    }

    func testProcessSnapshotSuppressesQuestionWhenQuestionEventsAreDisabled() async {
        let client = FakeTelegramMessagingClient()
        let observer = makeObserver(client: client, categoryEnabled: { category in
            category != .question
        })
        let session = makeSession(
            intervention: makeQuestionIntervention(),
            phase: .waitingForInput
        )

        await observer.processSnapshot([session])

        XCTAssertTrue(client.sentMessages.isEmpty)
    }

    func testProcessSnapshotEmitsCompletionAfterCompletedReadyTransition() async {
        let client = FakeTelegramMessagingClient()
        let observer = makeObserver(client: client)
        let processing = makeSession(phase: .processing)
        let completed = makeSession(
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(id: "assistant-1", type: .assistant("Done."), timestamp: Date(timeIntervalSince1970: 2))
            ]
        )

        await observer.processSnapshot([processing])
        await observer.processSnapshot([completed])

        XCTAssertEqual(client.sentMessages.count, 1)
        XCTAssertEqual(client.sentMessages.first?.replyMarkup, nil)
        XCTAssertEqual(client.sentMessages.first?.text.contains("Task completed"), true)
        XCTAssertEqual(client.sentMessages.first?.text.contains("Done."), true)
    }

    func testProcessSnapshotDoesNotReplayExistingCompletionOnFirstSnapshot() async {
        let client = FakeTelegramMessagingClient()
        let observer = makeObserver(client: client)
        let completed = makeSession(
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(id: "assistant-1", type: .assistant("Done."), timestamp: Date(timeIntervalSince1970: 2))
            ]
        )

        await observer.processSnapshot([completed])

        XCTAssertTrue(client.sentMessages.isEmpty)
    }

    func testProcessSnapshotEmitsErrorForNewCompletedErrorTool() async {
        let client = FakeTelegramMessagingClient()
        let observer = makeObserver(client: client)
        let beforeError = makeSession(phase: .processing)
        let afterError = makeSession(
            phase: .processing,
            completedErrorToolIDs: ["tool-error-1"]
        )

        await observer.processSnapshot([beforeError])
        await observer.processSnapshot([afterError])

        XCTAssertEqual(client.sentMessages.count, 1)
        XCTAssertEqual(client.sentMessages.first?.replyMarkup, nil)
        XCTAssertEqual(client.sentMessages.first?.text.contains("Task error"), true)
        XCTAssertEqual(client.sentMessages.first?.text.contains("tool-error-1"), true)
    }

    func testProcessSnapshotSuppressesErrorWhenErrorEventsAreDisabled() async {
        let client = FakeTelegramMessagingClient()
        let observer = makeObserver(client: client, categoryEnabled: { category in
            category != .error
        })
        let beforeError = makeSession(phase: .processing)
        let afterError = makeSession(
            phase: .processing,
            completedErrorToolIDs: ["tool-error-1"]
        )

        await observer.processSnapshot([beforeError])
        await observer.processSnapshot([afterError])

        XCTAssertTrue(client.sentMessages.isEmpty)
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

    func testFinalizeMacResponseEditsMessageAndDropsRegistries() async throws {
        let client = FakeTelegramMessagingClient()
        let stateStore = InMemoryTelegramStateStore(makeStoredMessageState())
        let observer = makeObserver(client: client, stateStore: stateStore)

        await observer.finalizeResponse(.init(
            sessionId: "session-1",
            interventionId: "tool-1",
            decision: .approveOnce,
            source: .mac,
            timestamp: Date(timeIntervalSince1970: 1_775_003_600)
        ))

        XCTAssertEqual(client.editedMessages.map(\.text), ["✅ Approved once · 在 Mac 上响应于 01:00"])
        XCTAssertNil(client.editedMessages.first?.replyMarkup)
        let state = try stateStore.load()
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.callbacks.isEmpty)
    }

    func testFinalizeTelegramResponseEditsMessageAndDropsRegistries() async throws {
        let client = FakeTelegramMessagingClient()
        let stateStore = InMemoryTelegramStateStore(makeStoredMessageState())
        let observer = makeObserver(client: client, stateStore: stateStore)

        await observer.finalizeResponse(.init(
            sessionId: "session-1",
            interventionId: "tool-1",
            decision: .deny(reason: nil),
            source: .telegram,
            timestamp: Date(timeIntervalSince1970: 1_775_003_600)
        ))

        XCTAssertEqual(client.editedMessages.map(\.text), ["✅ Denied · 来自 Telegram · 01:00"])
        let state = try stateStore.load()
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.callbacks.isEmpty)
    }

    private func makeStoredMessageState() -> TelegramPersistentState {
        TelegramPersistentState(
            messages: [
                InterventionKey.make(sessionId: "session-1", interventionId: "tool-1"): .init(
                    chatId: 123,
                    messageId: 456,
                    sentAt: Date(timeIntervalSince1970: 1_775_000_000)
                )
            ],
            callbacks: [
                "tok1": .init(
                    sessionId: "session-1",
                    interventionId: "tool-1",
                    action: .allowOnce,
                    issuedAt: Date(timeIntervalSince1970: 1_775_000_000)
                ),
                "tok2": .init(
                    sessionId: "session-1",
                    interventionId: "tool-1",
                    action: .deny,
                    issuedAt: Date(timeIntervalSince1970: 1_775_000_000)
                )
            ]
        )
    }

    private func makeObserver(
        client: FakeTelegramMessagingClient,
        stateStore: InMemoryTelegramStateStore = InMemoryTelegramStateStore(),
        categoryEnabled: @escaping (TelegramEventCategory) -> Bool = { _ in true }
    ) -> TelegramOutboundObserver {
        TelegramOutboundObserver(
            chatId: 123,
            client: client,
            messageRegistry: TelegramMessageRegistry(stateStore: stateStore),
            callbackRegistry: TelegramCallbackRegistry(stateStore: stateStore),
            rateLimitQueue: TelegramRateLimitQueue(minimumSpacing: 0),
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            timeFormatter: { _ in "01:00" },
            tokenProvider: SequentialTelegramTokenProvider().nextToken,
            categoryEnabled: categoryEnabled
        )
    }

    private func makeSession(
        intervention: SessionIntervention? = nil,
        phase: SessionPhase,
        chatItems: [ChatHistoryItem] = [],
        completedErrorToolIDs: Set<String> = []
    ) -> SessionState {
        SessionState(
            sessionId: "session-1",
            cwd: "/tmp/ping-island",
            projectName: "ping-island",
            provider: .claude,
            intervention: intervention,
            phase: phase,
            chatItems: chatItems,
            completedErrorToolIDs: completedErrorToolIDs
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

    private func makeQuestionIntervention() -> SessionIntervention {
        SessionIntervention(
            id: "question-intervention-1",
            kind: .question,
            title: "Need direction",
            message: "Pick one option",
            options: [],
            questions: [
                SessionInterventionQuestion(
                    id: "question-1",
                    header: "Need direction",
                    prompt: "Pick a path",
                    detail: "Pick one option",
                    options: [
                        .init(id: "a", title: "Option A", detail: nil),
                        .init(id: "b", title: "Option B", detail: nil)
                    ],
                    allowsMultiple: false,
                    allowsOther: false,
                    isSecret: false
                )
            ],
            supportsSessionScope: false,
            metadata: [:]
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
