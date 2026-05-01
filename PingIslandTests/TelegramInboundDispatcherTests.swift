import XCTest
@testable import Ping_Island

@MainActor
final class TelegramInboundDispatcherTests: XCTestCase {
    func testUnauthorizedCallbackIsDropped() async throws {
        let stateStore = InMemoryTelegramStateStore(TelegramPersistentState(auth: .init(chatId: 123)))
        let client = FakeTelegramInboundClient()
        let hub = FakeTelegramInboundHub()
        let dispatcher = makeDispatcher(stateStore: stateStore, client: client, hub: hub)

        await dispatcher.handle(makeUpdate(fromId: 999, callbackData: "v1|tok1|allow_once"))

        XCTAssertTrue(hub.approveCalls.isEmpty)
        XCTAssertTrue(client.editedMessages.isEmpty)
    }

    func testAllowOnceCallbackDispatchesApproveThroughHub() async throws {
        let stateStore = InMemoryTelegramStateStore(makeState(action: .allowOnce))
        let hub = FakeTelegramInboundHub()
        let dispatcher = makeDispatcher(stateStore: stateStore, hub: hub)

        await dispatcher.handle(makeUpdate(callbackData: "v1|tok1|allow_once"))

        XCTAssertEqual(hub.approveCalls, [
            .init(sessionId: "session-1", forSession: false, source: .telegram)
        ])
    }

    func testDenyCallbackDispatchesDenyThroughHub() async throws {
        let stateStore = InMemoryTelegramStateStore(makeState(action: .deny))
        let hub = FakeTelegramInboundHub()
        let dispatcher = makeDispatcher(stateStore: stateStore, hub: hub)

        await dispatcher.handle(makeUpdate(callbackData: "v1|tok1|deny"))

        XCTAssertEqual(hub.denyCalls, [
            .init(sessionId: "session-1", reason: nil, source: .telegram)
        ])
    }

    func testAnswerOptionCallbackDispatchesAnswerThroughHub() async throws {
        let stateStore = InMemoryTelegramStateStore(makeState(
            action: .answerOption(questionId: "question-1", optionTitle: "Option A")
        ))
        let hub = FakeTelegramInboundHub()
        let dispatcher = makeDispatcher(stateStore: stateStore, hub: hub)

        await dispatcher.handle(makeUpdate(callbackData: "v1|tok1|answer"))

        XCTAssertEqual(hub.answerCalls, [
            .init(sessionId: "session-1", answers: ["question-1": ["Option A"]], source: .telegram)
        ])
    }

    func testMissingTokenEditsAlreadyHandled() async throws {
        let stateStore = InMemoryTelegramStateStore(TelegramPersistentState(auth: .init(chatId: 123)))
        let client = FakeTelegramInboundClient()
        let dispatcher = makeDispatcher(stateStore: stateStore, client: client)

        await dispatcher.handle(makeUpdate(callbackData: "v1|missing|allow_once"))

        XCTAssertEqual(client.editedMessages.map(\.text), ["⏱ Already handled"])
    }

    func testDispatcherUnavailableEditsMacOffline() async throws {
        let stateStore = InMemoryTelegramStateStore(makeState(action: .allowOnce))
        let client = FakeTelegramInboundClient()
        let hub = FakeTelegramInboundHub(result: .failure(.dispatcherUnavailable))
        let dispatcher = makeDispatcher(stateStore: stateStore, client: client, hub: hub)

        await dispatcher.handle(makeUpdate(callbackData: "v1|tok1|allow_once"))

        XCTAssertEqual(client.editedMessages.map(\.text), ["⚠️ Mac not online"])
    }

    func testActionNotHandledEditsAlreadyHandled() async throws {
        let stateStore = InMemoryTelegramStateStore(makeState(action: .allowOnce))
        let client = FakeTelegramInboundClient()
        let hub = FakeTelegramInboundHub(result: .failure(.actionNotHandled))
        let dispatcher = makeDispatcher(stateStore: stateStore, client: client, hub: hub)

        await dispatcher.handle(makeUpdate(callbackData: "v1|tok1|allow_once"))

        XCTAssertEqual(client.editedMessages.map(\.text), ["⏱ Already handled"])
    }

    private func makeDispatcher(
        stateStore: InMemoryTelegramStateStore,
        client: FakeTelegramInboundClient = FakeTelegramInboundClient(),
        hub: FakeTelegramInboundHub? = nil
    ) -> TelegramInboundDispatcher {
        TelegramInboundDispatcher(
            stateStore: stateStore,
            callbackRegistry: TelegramCallbackRegistry(stateStore: stateStore),
            client: client,
            hub: hub ?? FakeTelegramInboundHub()
        )
    }

    private func makeState(
        action: TelegramPersistentState.CallbackResolution.Action
    ) -> TelegramPersistentState {
        TelegramPersistentState(
            auth: .init(chatId: 123),
            callbacks: [
                "tok1": .init(
                    sessionId: "session-1",
                    interventionId: "tool-1",
                    action: action,
                    issuedAt: Date(timeIntervalSince1970: 1_775_000_000)
                )
            ]
        )
    }

    private func makeUpdate(
        fromId: Int64 = 123,
        callbackData: String
    ) -> TelegramUpdate {
        TelegramUpdate(
            updateId: 1,
            message: nil,
            callbackQuery: .init(
                id: "callback-1",
                from: .init(id: fromId, isBot: false, username: "tester"),
                message: .init(
                    messageId: 456,
                    date: 1_775_000_000,
                    chat: .init(id: 123, type: "private"),
                    text: "Approval requested"
                ),
                data: callbackData
            )
        )
    }
}

private final class FakeTelegramInboundClient: TelegramMessagingClient {
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

private final class FakeTelegramInboundHub: TelegramInboundActionDispatching {
    struct ApproveCall: Equatable {
        let sessionId: String
        let forSession: Bool
        let source: InterventionResponse.Source
    }

    struct DenyCall: Equatable {
        let sessionId: String
        let reason: String?
        let source: InterventionResponse.Source
    }

    struct AnswerCall: Equatable {
        let sessionId: String
        let answers: [String: [String]]
        let source: InterventionResponse.Source
    }

    private let result: Result<Void, InterventionActionDispatchError>
    private(set) var approveCalls: [ApproveCall] = []
    private(set) var denyCalls: [DenyCall] = []
    private(set) var answerCalls: [AnswerCall] = []

    init(result: Result<Void, InterventionActionDispatchError> = .success(())) {
        self.result = result
    }

    func approvePermission(
        sessionId: String,
        forSession: Bool,
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError> {
        approveCalls.append(.init(sessionId: sessionId, forSession: forSession, source: source))
        return result
    }

    func denyPermission(
        sessionId: String,
        reason: String?,
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError> {
        denyCalls.append(.init(sessionId: sessionId, reason: reason, source: source))
        return result
    }

    func answerIntervention(
        sessionId: String,
        answers: [String: [String]],
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError> {
        answerCalls.append(.init(sessionId: sessionId, answers: answers, source: source))
        return result
    }
}
