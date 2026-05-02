import Combine
import XCTest
@testable import Ping_Island

@MainActor
final class TelegramServiceLifecycleTests: XCTestCase {
    func testMasterOffPollerNotStarted() async {
        var settings = TelegramSettings(defaults: makeDefaults())
        settings.masterEnabled = false
        let tokenStore = FakeTelegramServiceTokenStore(token: "123:abc")
        let stateStore = FakeTelegramServiceStateStore(chatId: 7)
        let factory = FakeTelegramPollerFactory()
        let service = TelegramService(
            settings: settings,
            tokenStore: tokenStore,
            stateStore: stateStore,
            pollerFactory: { await factory.makePoller($0) }
        )

        await service.refresh()

        let pollerCount = await factory.pollerCount()
        XCTAssertEqual(pollerCount, 0)
    }

    func testMasterOnPlusTokenPlusAuthPollerStarts() async {
        var settings = TelegramSettings(defaults: makeDefaults())
        settings.masterEnabled = true
        let tokenStore = FakeTelegramServiceTokenStore(token: "123:abc")
        let stateStore = FakeTelegramServiceStateStore(chatId: 7)
        let factory = FakeTelegramPollerFactory()
        let service = TelegramService(
            settings: settings,
            tokenStore: tokenStore,
            stateStore: stateStore,
            pollerFactory: { await factory.makePoller($0) }
        )

        await service.refresh()

        let poller = await factory.poller(at: 0)
        let tokens = await factory.tokens()
        let startCount = await poller.startCount
        XCTAssertEqual(tokens, ["123:abc"])
        XCTAssertEqual(startCount, 1)
    }

    func testMasterOnPlusTokenPlusAuthOutboundObserverStarts() async {
        var settings = TelegramSettings(defaults: makeDefaults())
        settings.masterEnabled = true
        let outboundFactory = FakeTelegramOutboundObserverFactory()
        let service = TelegramService(
            settings: settings,
            tokenStore: FakeTelegramServiceTokenStore(token: "123:abc"),
            stateStore: FakeTelegramServiceStateStore(chatId: 7),
            pollerFactory: { _ in FakeTelegramPolling() },
            outboundObserverFactory: { token, chatId in
                outboundFactory.makeObserver(token: token, chatId: chatId)
            }
        )

        await service.refresh()

        XCTAssertEqual(outboundFactory.requests.map(\.token), ["123:abc"])
        XCTAssertEqual(outboundFactory.requests.map(\.chatId), [7])
        XCTAssertEqual(outboundFactory.observers.first?.startCount, 1)
    }

    func testMasterTogglesOffPollerStops() async {
        let defaults = makeDefaults()
        var settings = TelegramSettings(defaults: defaults)
        settings.masterEnabled = true
        let tokenStore = FakeTelegramServiceTokenStore(token: "123:abc")
        let stateStore = FakeTelegramServiceStateStore(chatId: 7)
        let factory = FakeTelegramPollerFactory()
        let service = TelegramService(
            settings: settings,
            tokenStore: tokenStore,
            stateStore: stateStore,
            pollerFactory: { await factory.makePoller($0) }
        )

        await service.refresh()
        settings.masterEnabled = false
        await service.refresh()

        let poller = await factory.poller(at: 0)
        let stopCount = await poller.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testMasterTogglesOffOutboundObserverStops() async {
        let defaults = makeDefaults()
        var settings = TelegramSettings(defaults: defaults)
        settings.masterEnabled = true
        let outboundFactory = FakeTelegramOutboundObserverFactory()
        let service = TelegramService(
            settings: settings,
            tokenStore: FakeTelegramServiceTokenStore(token: "123:abc"),
            stateStore: FakeTelegramServiceStateStore(chatId: 7),
            pollerFactory: { _ in FakeTelegramPolling() },
            outboundObserverFactory: { token, chatId in
                outboundFactory.makeObserver(token: token, chatId: chatId)
            }
        )

        await service.refresh()
        settings.masterEnabled = false
        await service.refresh()

        XCTAssertEqual(outboundFactory.observers.first?.stopCount, 1)
    }

    func testBeginPairingOpensAuthWindow() async {
        let authState = FakeTelegramServiceAuthState()
        let service = TelegramService(
            settings: TelegramSettings(defaults: makeDefaults()),
            tokenStore: FakeTelegramServiceTokenStore(token: nil),
            stateStore: FakeTelegramServiceStateStore(chatId: nil),
            authState: authState,
            pollerFactory: { _ in FakeTelegramPolling() }
        )

        await service.beginPairing()

        let openedTimeouts = await authState.openedTimeouts()
        XCTAssertEqual(openedTimeouts, [300])
    }

    func testInboundMessageDelegatesChatToAuthState() async {
        var settings = TelegramSettings(defaults: makeDefaults())
        settings.masterEnabled = true
        let authState = FakeTelegramServiceAuthState()
        let factory = FakeTelegramPollerFactory()
        let service = TelegramService(
            settings: settings,
            tokenStore: FakeTelegramServiceTokenStore(token: "123:abc"),
            stateStore: FakeTelegramServiceStateStore(chatId: 7),
            authState: authState,
            pollerFactory: { await factory.makePoller($0) }
        )

        await service.refresh()
        let poller = await factory.poller(at: 0)
        await poller.emit(TelegramUpdate(
            updateId: 1,
            message: TelegramMessage(
                messageId: 2,
                date: 0,
                chat: TelegramChat(id: 7, type: "private"),
                text: "/start"
            ),
            callbackQuery: nil
        ))

        let handledChatIds = await authState.handledChatIds()
        XCTAssertEqual(handledChatIds, [7])
    }

    func testInboundCallbackDelegatesToDispatcher() async {
        var settings = TelegramSettings(defaults: makeDefaults())
        settings.masterEnabled = true
        let authState = FakeTelegramServiceAuthState()
        let factory = FakeTelegramPollerFactory()
        let inboundFactory = FakeTelegramInboundDispatcherFactory()
        let service = TelegramService(
            settings: settings,
            tokenStore: FakeTelegramServiceTokenStore(token: "123:abc"),
            stateStore: FakeTelegramServiceStateStore(chatId: 7),
            authState: authState,
            pollerFactory: { await factory.makePoller($0) },
            inboundDispatcherFactory: { token, _ in
                inboundFactory.makeDispatcher(token: token)
            }
        )

        await service.refresh()
        let poller = await factory.poller(at: 0)
        let update = TelegramUpdate(
            updateId: 1,
            message: nil,
            callbackQuery: TelegramCallbackQuery(
                id: "callback-1",
                from: TelegramUser(id: 7, isBot: false, username: "tester"),
                message: TelegramMessage(
                    messageId: 2,
                    date: 0,
                    chat: TelegramChat(id: 7, type: "private"),
                    text: "Approval"
                ),
                data: "v1|tok1|allow_once"
            )
        )

        await poller.emit(update)

        XCTAssertEqual(inboundFactory.requests, ["123:abc"])
        XCTAssertEqual(inboundFactory.dispatchers.first?.updates, [update])
        let handledChatIds = await authState.handledChatIds()
        XCTAssertTrue(handledChatIds.isEmpty)
    }

    func testReadyRefreshRunsRestartSweepOnceBeforeOutboundObserverStarts() async {
        var settings = TelegramSettings(defaults: makeDefaults())
        settings.masterEnabled = true
        let outboundFactory = FakeTelegramOutboundObserverFactory()
        let sweepFactory = FakeTelegramRestartSweeperFactory()
        let activeSession = SessionState(sessionId: "active-session", cwd: "/tmp/ping-island")
        let service = TelegramService(
            settings: settings,
            tokenStore: FakeTelegramServiceTokenStore(token: "123:abc"),
            stateStore: FakeTelegramServiceStateStore(chatId: 7),
            pollerFactory: { _ in FakeTelegramPolling() },
            outboundObserverFactory: { token, chatId in
                outboundFactory.makeObserver(token: token, chatId: chatId)
            },
            restartSweeperFactory: { token, _ in
                sweepFactory.makeSweeper(token: token)
            },
            activeSessionsProvider: {
                [activeSession]
            }
        )

        await service.refresh()
        await service.refresh()

        XCTAssertEqual(sweepFactory.requests, ["123:abc"])
        XCTAssertEqual(sweepFactory.sweepers.first?.sweptSessions.map { $0.map(\.sessionId) }, [["active-session"]])
        XCTAssertEqual(outboundFactory.observers.first?.startCount, 1)
        XCTAssertLessThan(
            sweepFactory.sweepers.first?.firstSweepOrder ?? .max,
            outboundFactory.observers.first?.firstStartOrder ?? .min
        )
    }

    private func makeDefaults(
        _ testName: StaticString = #function
    ) -> UserDefaults {
        let suiteName = "PingIslandTests.TelegramService.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor FakeTelegramPollerFactory {
    private var madePollers: [FakeTelegramPolling] = []
    private var madeTokens: [String] = []

    func makePoller(_ token: String) -> TelegramPolling {
        madeTokens.append(token)
        let poller = FakeTelegramPolling()
        madePollers.append(poller)
        return poller
    }

    func pollerCount() -> Int {
        madePollers.count
    }

    func poller(at index: Int) -> FakeTelegramPolling {
        madePollers[index]
    }

    func tokens() -> [String] {
        madeTokens
    }
}

private actor FakeTelegramPolling: TelegramPolling {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@Sendable (TelegramUpdate) async -> Void)?

    func start(handler: @escaping @Sendable (TelegramUpdate) async -> Void) async {
        startCount += 1
        self.handler = handler
    }

    func stop() async {
        stopCount += 1
    }

    func emit(_ update: TelegramUpdate) async {
        await handler?(update)
    }
}

@MainActor
private final class FakeTelegramOutboundObserverFactory {
    struct Request {
        let token: String
        let chatId: Int64
    }

    private(set) var requests: [Request] = []
    private(set) var observers: [FakeTelegramOutboundObserver] = []

    func makeObserver(token: String, chatId: Int64) -> TelegramOutboundObserving {
        requests.append(.init(token: token, chatId: chatId))
        let observer = FakeTelegramOutboundObserver()
        observers.append(observer)
        return observer
    }
}

private final class FakeTelegramOutboundObserver: TelegramOutboundObserving {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var firstStartOrder: Int?

    func start(publisher: AnyPublisher<[SessionState], Never>) {
        if firstStartOrder == nil {
            firstStartOrder = TelegramServiceLifecycleOrder.next()
        }
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class FakeTelegramRestartSweeperFactory {
    private(set) var requests: [String] = []
    private(set) var sweepers: [FakeTelegramRestartSweeper] = []

    func makeSweeper(token: String) -> TelegramRestartSweeping {
        requests.append(token)
        let sweeper = FakeTelegramRestartSweeper()
        sweepers.append(sweeper)
        return sweeper
    }
}

@MainActor
private final class FakeTelegramRestartSweeper: TelegramRestartSweeping {
    private(set) var sweptSessions: [[SessionState]] = []
    private(set) var firstSweepOrder: Int?

    func sweep(activeSessions: [SessionState]) async {
        if firstSweepOrder == nil {
            firstSweepOrder = TelegramServiceLifecycleOrder.next()
        }
        sweptSessions.append(activeSessions)
    }
}

private enum TelegramServiceLifecycleOrder {
    private nonisolated(unsafe) static var value = 0

    static func next() -> Int {
        value += 1
        return value
    }
}

@MainActor
private final class FakeTelegramInboundDispatcherFactory {
    private(set) var requests: [String] = []
    private(set) var dispatchers: [FakeTelegramInboundDispatcher] = []

    func makeDispatcher(token: String) -> TelegramInboundDispatching {
        requests.append(token)
        let dispatcher = FakeTelegramInboundDispatcher()
        dispatchers.append(dispatcher)
        return dispatcher
    }
}

private final class FakeTelegramInboundDispatcher: TelegramInboundDispatching {
    private(set) var updates: [TelegramUpdate] = []

    func handle(_ update: TelegramUpdate) async {
        updates.append(update)
    }
}

private actor FakeTelegramServiceAuthState: TelegramAuthControlling {
    private var timeouts: [TimeInterval] = []
    private var chatIds: [Int64] = []

    func openPairingWindow(timeout: TimeInterval) {
        timeouts.append(timeout)
    }

    func handleIncomingMessage(from incomingChatId: Int64) -> TelegramAuthState.AuthDecision {
        chatIds.append(incomingChatId)
        return .dropped
    }

    func openedTimeouts() -> [TimeInterval] {
        timeouts
    }

    func handledChatIds() -> [Int64] {
        chatIds
    }
}

private final class FakeTelegramServiceTokenStore: TelegramTokenStoring {
    private let token: String?

    init(token: String?) {
        self.token = token
    }

    func save(_ token: String) throws {}

    func load() throws -> String? {
        token
    }

    func clear() throws {}
}

private final class FakeTelegramServiceStateStore: TelegramStateStoring {
    private let state: TelegramPersistentState

    init(chatId: Int64?) {
        self.state = TelegramPersistentState(auth: .init(chatId: chatId))
    }

    func load() throws -> TelegramPersistentState {
        state
    }

    func save(_ state: TelegramPersistentState) throws {}
}
