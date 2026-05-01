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

    func start(handler: @escaping @Sendable (TelegramUpdate) async -> Void) async {
        startCount += 1
    }

    func stop() async {
        stopCount += 1
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
