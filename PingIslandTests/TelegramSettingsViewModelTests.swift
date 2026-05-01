import XCTest
@testable import Ping_Island

@MainActor
final class TelegramSettingsViewModelTests: XCTestCase {
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
