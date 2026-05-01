import XCTest
@testable import Ping_Island

final class TelegramSettingsTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDownWithError() throws {
        for suiteName in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        try super.tearDownWithError()
    }

    func testDefaultsKeepMasterOffButPermissionAndQuestionSelected() {
        let settings = TelegramSettings(defaults: makeDefaults())

        XCTAssertFalse(settings.masterEnabled)
        XCTAssertTrue(settings.permissionEvents)
        XCTAssertTrue(settings.questionEvents)
        XCTAssertFalse(settings.completionEvents)
        XCTAssertFalse(settings.errorEvents)
        XCTAssertFalse(settings.limitEvents)
    }

    func testEventEnabledRequiresMasterAndEventToggle() {
        var settings = TelegramSettings(defaults: makeDefaults())

        XCTAssertFalse(settings.isEnabled(for: .permission))
        XCTAssertFalse(settings.isEnabled(for: .question))

        settings.masterEnabled = true

        XCTAssertTrue(settings.isEnabled(for: .permission))
        XCTAssertTrue(settings.isEnabled(for: .question))
        XCTAssertFalse(settings.isEnabled(for: .completion))
    }

    func testRoundTripsTogglesThroughUserDefaults() {
        let defaults = makeDefaults()
        var settings = TelegramSettings(defaults: defaults)

        settings.masterEnabled = true
        settings.permissionEvents = false
        settings.questionEvents = false
        settings.completionEvents = true
        settings.errorEvents = true
        settings.limitEvents = true

        let reloaded = TelegramSettings(defaults: defaults)

        XCTAssertTrue(reloaded.masterEnabled)
        XCTAssertFalse(reloaded.permissionEvents)
        XCTAssertFalse(reloaded.questionEvents)
        XCTAssertTrue(reloaded.completionEvents)
        XCTAssertTrue(reloaded.errorEvents)
        XCTAssertTrue(reloaded.limitEvents)
    }

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "PingIslandTests.TelegramSettings.\(testName).\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
