import XCTest
@testable import Ping_Island

final class SettingsCategoryTests: XCTestCase {
    func testTelegramCategorySitsBetweenIntegrationAndRemote() {
        XCTAssertEqual(
            SettingsCategory.allCases,
            [.general, .shortcuts, .display, .mascot, .sound, .integration, .telegram, .remote, .about]
        )
    }

    func testTelegramCategoryMetadata() {
        XCTAssertEqual(SettingsCategory.telegram.title, "Telegram")
        XCTAssertEqual(SettingsCategory.telegram.subtitle, "远程通知与远程批准")
        XCTAssertEqual(SettingsCategory.telegram.icon, "paperplane.fill")
    }
}
