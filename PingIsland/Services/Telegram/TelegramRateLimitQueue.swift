import Foundation

actor TelegramRateLimitQueue {
    private let minimumSpacing: TimeInterval
    private let now: @Sendable () async -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var nextAvailableAt: [Int64: Date] = [:]

    init(
        minimumSpacing: TimeInterval = 1.05,
        now: @escaping @Sendable () async -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { duration in
            guard duration > 0 else { return }
            let nanoseconds = UInt64(duration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.minimumSpacing = minimumSpacing
        self.now = now
        self.sleep = sleep
    }

    func enqueue(
        chatId: Int64,
        work: @Sendable () async -> Result<Void, TelegramAPIError>
    ) async {
        while true {
            let current = await now()
            if let nextAvailable = nextAvailableAt[chatId], current < nextAvailable {
                await sleep(nextAvailable.timeIntervalSince(current))
                continue
            }

            let attemptTime = await now()
            nextAvailableAt[chatId] = attemptTime.addingTimeInterval(minimumSpacing)

            switch await work() {
            case .success:
                return
            case .failure(.rateLimited(let retryAfterSeconds)):
                nextAvailableAt[chatId] = attemptTime.addingTimeInterval(retryAfterSeconds)
                continue
            case .failure:
                return
            }
        }
    }
}
