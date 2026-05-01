import XCTest
@testable import Ping_Island

final class TelegramAuthStateTests: XCTestCase {
    func testOpenAndClosePairingWindow() async {
        let authState = TelegramAuthState(
            stateStore: FakeTelegramAuthStateStore(),
            now: { Date(timeIntervalSinceReferenceDate: 10) }
        )

        let initiallyOpen = await authState.isPairingOpen
        XCTAssertFalse(initiallyOpen)
        await authState.openPairingWindow(timeout: 300)
        let opened = await authState.isPairingOpen
        XCTAssertTrue(opened)
        await authState.closePairingWindow()
        let closed = await authState.isPairingOpen
        XCTAssertFalse(closed)
    }

    func testIncomingMessageWithoutPairingWindowDrops() async {
        let store = FakeTelegramAuthStateStore()
        let authState = TelegramAuthState(
            stateStore: store,
            now: { Date(timeIntervalSinceReferenceDate: 10) }
        )

        let decision = await authState.handleIncomingMessage(from: 7)

        XCTAssertEqual(decision, .dropped)
        XCTAssertNil(store.state.auth.chatId)
    }

    func testOpenWindowCapturesFirstIncomingChatAndPersists() async {
        let store = FakeTelegramAuthStateStore()
        let authState = TelegramAuthState(
            stateStore: store,
            now: { Date(timeIntervalSinceReferenceDate: 10) }
        )

        await authState.openPairingWindow(timeout: 300)
        let decision = await authState.handleIncomingMessage(from: 7)

        XCTAssertEqual(decision, .captured(chatId: 7))
        XCTAssertEqual(store.state.auth.chatId, 7)
        let isPairingOpen = await authState.isPairingOpen
        XCTAssertFalse(isPairingOpen)
    }

    func testAlreadyPairedReturnsAlreadyPairedAndDoesNotOverwrite() async {
        let store = FakeTelegramAuthStateStore(chatId: 7)
        let authState = TelegramAuthState(
            stateStore: store,
            now: { Date(timeIntervalSinceReferenceDate: 10) }
        )

        await authState.openPairingWindow(timeout: 300)
        let decision = await authState.handleIncomingMessage(from: 8)

        XCTAssertEqual(decision, .alreadyPaired)
        XCTAssertEqual(store.state.auth.chatId, 7)
    }

    func testExpiredPairingWindowDrops() async {
        let clock = FakeTelegramAuthClock(now: 10)
        let store = FakeTelegramAuthStateStore()
        let authState = TelegramAuthState(
            stateStore: store,
            now: { await clock.date() }
        )

        await authState.openPairingWindow(timeout: 5)
        await clock.advance(by: 6)
        let decision = await authState.handleIncomingMessage(from: 7)

        XCTAssertEqual(decision, .dropped)
        XCTAssertNil(store.state.auth.chatId)
        let isPairingOpen = await authState.isPairingOpen
        XCTAssertFalse(isPairingOpen)
    }
}

private actor FakeTelegramAuthClock {
    private var currentTime: TimeInterval

    init(now: TimeInterval) {
        self.currentTime = now
    }

    func date() -> Date {
        Date(timeIntervalSinceReferenceDate: currentTime)
    }

    func advance(by duration: TimeInterval) {
        currentTime += duration
    }
}

private final class FakeTelegramAuthStateStore: TelegramStateStoring {
    private(set) var state: TelegramPersistentState

    init(chatId: Int64? = nil) {
        self.state = TelegramPersistentState(auth: .init(chatId: chatId))
    }

    func load() throws -> TelegramPersistentState {
        state
    }

    func save(_ state: TelegramPersistentState) throws {
        self.state = state
    }
}
