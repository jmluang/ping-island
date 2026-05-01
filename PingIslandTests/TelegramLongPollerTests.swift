import XCTest
@testable import Ping_Island

final class TelegramLongPollerTests: XCTestCase {
    func testStartDrivesTwoBatchesHandlerSeesAllUpdates() async {
        let client = FakeTelegramUpdatesClient(results: [
            .success([
                makeUpdate(100),
                makeUpdate(101)
            ]),
            .success([
                makeUpdate(102)
            ])
        ])
        let stateStore = FakeTelegramStateStore()
        let poller = TelegramLongPoller(client: client, stateStore: stateStore)
        let handledUpdates = UpdateCollector()

        await poller.start { update in
            await handledUpdates.append(update)
        }
        await client.waitForCallCount(2)
        await poller.stop()

        let updateIds = await handledUpdates.updateIds
        XCTAssertEqual(updateIds, [100, 101, 102])
    }

    func testOffsetPersistedAfterEachBatch() async {
        let client = FakeTelegramUpdatesClient(results: [
            .success([
                makeUpdate(100)
            ]),
            .success([
                makeUpdate(101),
                makeUpdate(102)
            ])
        ])
        let stateStore = FakeTelegramStateStore()
        let poller = TelegramLongPoller(client: client, stateStore: stateStore)

        await poller.start { _ in }
        await client.waitForCallCount(2)
        await poller.stop()

        XCTAssertEqual(stateStore.savedOffsets, [101, 103])
    }

    func testStopHaltsLoop() async {
        let client = FakeTelegramUpdatesClient(results: [], suspendsWhenExhausted: true)
        let poller = TelegramLongPoller(client: client, stateStore: FakeTelegramStateStore())

        await poller.start { _ in }
        await client.waitForCallCount(1)

        let runningBeforeStop = await poller.isRunning
        XCTAssertTrue(runningBeforeStop)
        await poller.stop()
        let runningAfterStop = await poller.isRunning
        XCTAssertFalse(runningAfterStop)
    }

    private func makeUpdate(_ updateId: Int64) -> TelegramUpdate {
        TelegramUpdate(updateId: updateId, message: nil, callbackQuery: nil)
    }
}

private actor UpdateCollector {
    private var updates: [TelegramUpdate] = []

    var updateIds: [Int64] {
        updates.map(\.updateId)
    }

    func append(_ update: TelegramUpdate) {
        updates.append(update)
    }
}

private actor FakeTelegramUpdatesClient: TelegramUpdatesClient {
    private var results: [Result<[TelegramUpdate], TelegramAPIError>]
    private let suspendsWhenExhausted: Bool
    private var callCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        results: [Result<[TelegramUpdate], TelegramAPIError>],
        suspendsWhenExhausted: Bool = false
    ) {
        self.results = results
        self.suspendsWhenExhausted = suspendsWhenExhausted
    }

    func getUpdates(
        offset: Int64?,
        timeoutSeconds: Int,
        allowedUpdates: [String]
    ) async -> Result<[TelegramUpdate], TelegramAPIError> {
        callCount += 1
        resumeSatisfiedWaiters()
        guard !results.isEmpty else {
            if suspendsWhenExhausted {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
            return .success([])
        }
        return results.removeFirst()
    }

    func waitForCallCount(_ expected: Int) async {
        if callCount >= expected {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append((expected, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        let ready = waiters.filter { callCount >= $0.0 }
        waiters.removeAll { callCount >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

private final class FakeTelegramStateStore: TelegramStateStoring {
    private(set) var state = TelegramPersistentState()
    private(set) var savedOffsets: [Int64?] = []

    func load() throws -> TelegramPersistentState {
        state
    }

    func save(_ state: TelegramPersistentState) throws {
        self.state = state
        savedOffsets.append(state.poller.offset)
    }
}
