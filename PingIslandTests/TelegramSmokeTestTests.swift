import XCTest
@testable import Ping_Island

final class TelegramSmokeTestTests: XCTestCase {
    func testMarkerIsReachable() {
        XCTAssertEqual(TelegramSmokeTest.marker, "telegram-module-loaded")
    }
}
