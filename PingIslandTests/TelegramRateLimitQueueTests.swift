import XCTest
@testable import Ping_Island

final class TelegramRateLimitQueueTests: XCTestCase {
    func testSingleChatTwoCallsAtOnceSecondCallDelayedByMinSpacing() async {
        let clock = FakeTelegramRateLimitClock()
        let recorder = TelegramRateLimitWorkRecorder(clock: clock)
        let queue = TelegramRateLimitQueue(
            now: { await clock.date() },
            sleep: { await clock.sleep(for: $0) }
        )

        await queue.enqueue(chatId: 7) { await recorder.recordSuccess() }
        await queue.enqueue(chatId: 7) { await recorder.recordSuccess() }

        let attempts = await recorder.attemptTimes()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0], 0, accuracy: 0.0001)
        XCTAssertEqual(attempts[1], 1.05, accuracy: 0.0001)
    }

    func testDifferentChatsNoCrossChatBlocking() async {
        let clock = FakeTelegramRateLimitClock()
        let recorder = TelegramRateLimitWorkRecorder(clock: clock)
        let queue = TelegramRateLimitQueue(
            now: { await clock.date() },
            sleep: { await clock.sleep(for: $0) }
        )

        await queue.enqueue(chatId: 7) { await recorder.recordSuccess() }
        await queue.enqueue(chatId: 8) { await recorder.recordSuccess() }

        let attempts = await recorder.attemptTimes()
        let sleeps = await clock.sleepDurations()
        XCTAssertEqual(attempts, [0, 0])
        XCTAssertEqual(sleeps, [])
    }

    func test429ResponseHonorsRetryAfter() async {
        let clock = FakeTelegramRateLimitClock()
        let recorder = TelegramRateLimitWorkRecorder(clock: clock)
        let queue = TelegramRateLimitQueue(
            now: { await clock.date() },
            sleep: { await clock.sleep(for: $0) }
        )

        await queue.enqueue(chatId: 7) { await recorder.recordRateLimitThenSuccess(retryAfterSeconds: 3) }

        let attempts = await recorder.attemptTimes()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0], 0, accuracy: 0.0001)
        XCTAssertEqual(attempts[1], 3, accuracy: 0.0001)
    }
}

private actor FakeTelegramRateLimitClock {
    private var currentTime: TimeInterval = 0
    private var sleeps: [TimeInterval] = []

    func date() -> Date {
        Date(timeIntervalSinceReferenceDate: currentTime)
    }

    func time() -> TimeInterval {
        currentTime
    }

    func sleep(for duration: TimeInterval) {
        sleeps.append(duration)
        currentTime += duration
    }

    func sleepDurations() -> [TimeInterval] {
        sleeps
    }
}

private actor TelegramRateLimitWorkRecorder {
    private let clock: FakeTelegramRateLimitClock
    private var times: [TimeInterval] = []
    private var rateLimitedAttemptCount = 0

    init(clock: FakeTelegramRateLimitClock) {
        self.clock = clock
    }

    func recordSuccess() async -> Result<Void, TelegramAPIError> {
        times.append(await clock.time())
        return .success(())
    }

    func recordRateLimitThenSuccess(retryAfterSeconds: TimeInterval) async -> Result<Void, TelegramAPIError> {
        times.append(await clock.time())
        rateLimitedAttemptCount += 1
        if rateLimitedAttemptCount == 1 {
            return .failure(.rateLimited(retryAfterSeconds: retryAfterSeconds))
        }
        return .success(())
    }

    func attemptTimes() -> [TimeInterval] {
        times
    }
}
