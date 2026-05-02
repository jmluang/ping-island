import XCTest
import Combine
@testable import Ping_Island

@MainActor
final class TelegramSettingsViewModelTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDownWithError() throws {
        for suiteName in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        try super.tearDownWithError()
    }

    func testInitLoadsExistingToken() {
        let store = FakeTelegramTokenStore(token: "123:abc")

        let viewModel = TelegramSettingsViewModel(tokenStore: store)

        XCTAssertEqual(viewModel.tokenInput, "123:abc")
    }

    func testSaveAndTestStoresTokenAndMarksConnectionOK() async {
        let store = FakeTelegramTokenStore()
        let fakeClient = FakeTelegramGetMeClient(result: .success(TelegramUser(
            id: 1,
            isBot: true,
            username: "ping_island_bot"
        )))
        let viewModel = TelegramSettingsViewModel(
            tokenStore: store,
            clientFactory: { token in
                XCTAssertEqual(token, "123:abc")
                return fakeClient
            }
        )
        viewModel.tokenInput = " 123:abc "

        await viewModel.saveAndTest()

        XCTAssertEqual(store.savedToken, "123:abc")
        XCTAssertEqual(viewModel.connectionState, .ok("ping_island_bot"))
    }

    func testSaveAndTestMapsUnauthorizedToInvalidToken() async {
        let store = FakeTelegramTokenStore()
        let viewModel = TelegramSettingsViewModel(
            tokenStore: store,
            clientFactory: { _ in
                FakeTelegramGetMeClient(result: .failure(.botApi(errorCode: 401, description: "Unauthorized")))
            }
        )
        viewModel.tokenInput = "bad"

        await viewModel.saveAndTest()

        XCTAssertEqual(viewModel.connectionState, .invalidToken)
    }

    func testSaveAndTestMapsTransportFailureToNetworkError() async {
        let store = FakeTelegramTokenStore()
        let viewModel = TelegramSettingsViewModel(
            tokenStore: store,
            clientFactory: { _ in
                FakeTelegramGetMeClient(result: .failure(.transport("offline")))
            }
        )
        viewModel.tokenInput = "123:abc"

        await viewModel.saveAndTest()

        XCTAssertEqual(viewModel.connectionState, .networkError)
    }

    func testEmptyTokenDoesNotSaveAndMarksInvalidToken() async {
        let store = FakeTelegramTokenStore()
        let viewModel = TelegramSettingsViewModel(tokenStore: store)
        viewModel.tokenInput = "  "

        await viewModel.saveAndTest()

        XCTAssertNil(store.savedToken)
        XCTAssertEqual(viewModel.connectionState, .invalidToken)
    }

    func testStartPairingCallsServiceAndMarksWindowOpen() async {
        let pairingRecorder = PairingRecorder()
        let viewModel = TelegramSettingsViewModel(
            tokenStore: FakeTelegramTokenStore(),
            beginPairing: {
                await pairingRecorder.record()
            }
        )

        await viewModel.startPairing()

        let pairingCallCount = await pairingRecorder.callCount()
        XCTAssertEqual(pairingCallCount, 1)
        XCTAssertEqual(viewModel.pairingState, .open)
    }

    func testInitLoadsEventTogglesAndPersistsChanges() {
        let defaults = makeDefaults()
        var settings = TelegramSettings(defaults: defaults)
        settings.masterEnabled = true
        settings.permissionEvents = false
        settings.questionEvents = true
        settings.completionEvents = true
        settings.errorEvents = false
        settings.limitEvents = false

        let viewModel = TelegramSettingsViewModel(
            tokenStore: FakeTelegramTokenStore(),
            settings: settings
        )

        XCTAssertTrue(viewModel.masterEnabled)
        XCTAssertFalse(viewModel.permissionEvents)
        XCTAssertTrue(viewModel.questionEvents)
        XCTAssertTrue(viewModel.completionEvents)
        XCTAssertFalse(viewModel.errorAndLimitEvents)

        viewModel.setMasterEnabled(false)
        viewModel.setPermissionEvents(true)
        viewModel.setQuestionEvents(false)
        viewModel.setCompletionEvents(false)
        viewModel.setErrorAndLimitEvents(true)

        let reloaded = TelegramSettings(defaults: defaults)
        XCTAssertFalse(reloaded.masterEnabled)
        XCTAssertTrue(reloaded.permissionEvents)
        XCTAssertFalse(reloaded.questionEvents)
        XCTAssertFalse(reloaded.completionEvents)
        XCTAssertTrue(reloaded.errorEvents)
        XCTAssertTrue(reloaded.limitEvents)
    }

    func testDiagnosticsPublisherUpdatesViewModelAndTestNotificationState() async {
        let diagnostics = PassthroughSubject<TelegramDiagnosticsState, Never>()
        var sendCount = 0
        let viewModel = TelegramSettingsViewModel(
            tokenStore: FakeTelegramTokenStore(),
            diagnosticsPublisher: diagnostics.eraseToAnyPublisher(),
            sendTestNotification: {
                sendCount += 1
                return .success(())
            }
        )
        let state = TelegramDiagnosticsState(
            lastSuccessfulGetUpdatesAt: Date(timeIntervalSince1970: 1_775_000_000),
            lastError: "offline",
            inFlightMessageCount: 2
        )

        diagnostics.send(state)
        await viewModel.sendTestNotification()

        XCTAssertEqual(viewModel.diagnostics, state)
        XCTAssertEqual(viewModel.testNotificationState, .sent)
        XCTAssertEqual(sendCount, 1)
    }

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "PingIslandTests.TelegramSettingsViewModel.\(testName).\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor PairingRecorder {
    private var calls = 0

    func record() {
        calls += 1
    }

    func callCount() -> Int {
        calls
    }
}

private final class FakeTelegramTokenStore: TelegramTokenStoring {
    private let token: String?
    private(set) var savedToken: String?

    init(token: String? = nil) {
        self.token = token
    }

    func save(_ token: String) throws {
        savedToken = token
    }

    func load() throws -> String? {
        token
    }

    func clear() throws {
        savedToken = nil
    }
}

private struct FakeTelegramGetMeClient: TelegramGetMeClient {
    let result: Result<TelegramUser, TelegramAPIError>

    func getMe() async -> Result<TelegramUser, TelegramAPIError> {
        result
    }
}
