import XCTest
@testable import Ping_Island

final class TelegramTokenStoreTests: XCTestCase {
    func testSaveThenLoadReturnsSameToken() throws {
        let store = makeStore()
        defer { try? store.clear() }

        try store.save("123:abc")

        XCTAssertEqual(try store.load(), "123:abc")
    }

    func testSaveOverwritesExistingToken() throws {
        let store = makeStore()
        defer { try? store.clear() }

        try store.save("old")
        try store.save("new")

        XCTAssertEqual(try store.load(), "new")
    }

    func testClearThenLoadReturnsNil() throws {
        let store = makeStore()
        defer { try? store.clear() }

        try store.save("123:abc")
        try store.clear()

        XCTAssertNil(try store.load())
    }

    private func makeStore() -> TelegramTokenStore {
        TelegramTokenStore(service: "app.pingisland.telegram.tests.\(UUID().uuidString)")
    }
}
