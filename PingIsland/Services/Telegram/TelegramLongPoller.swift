import Foundation

protocol TelegramPolling: Sendable {
    func start(handler: @escaping @Sendable (TelegramUpdate) async -> Void) async
    func stop() async
}

actor TelegramLongPoller: TelegramPolling {
    private let client: TelegramUpdatesClient
    private let stateStore: TelegramStateStoring
    private let onInvalidToken: @Sendable () async -> Void
    private let sleep: @Sendable (TimeInterval) async -> Void

    private var pollingTask: Task<Void, Never>?

    init(
        client: TelegramUpdatesClient,
        stateStore: TelegramStateStoring = TelegramStateStore(),
        onInvalidToken: @escaping @Sendable () async -> Void = {},
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { duration in
            guard duration > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        }
    ) {
        self.client = client
        self.stateStore = stateStore
        self.onInvalidToken = onInvalidToken
        self.sleep = sleep
    }

    var isRunning: Bool {
        pollingTask != nil
    }

    func start(handler: @escaping @Sendable (TelegramUpdate) async -> Void) async {
        guard pollingTask == nil else {
            return
        }

        pollingTask = Task { [weak self] in
            await self?.poll(handler: handler)
        }
    }

    func stop() async {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func poll(handler: @escaping @Sendable (TelegramUpdate) async -> Void) async {
        var offset = loadOffset()
        var retryDelay: TimeInterval = 1

        while !Task.isCancelled {
            let result = await client.getUpdates(
                offset: offset,
                timeoutSeconds: 30,
                allowedUpdates: ["message", "callback_query"]
            )

            switch result {
            case .success(let updates):
                retryDelay = 1

                if let nextOffset = updates.map(\.updateId).max().map({ $0 + 1 }) {
                    offset = nextOffset
                    saveOffset(nextOffset)
                }

                for update in updates where !Task.isCancelled {
                    await handler(update)
                }
            case .failure(let error):
                if error.isUnauthorized {
                    pollingTask = nil
                    await onInvalidToken()
                    return
                }
                let delay = error.retryDelay(defaultDelay: retryDelay)
                await sleep(delay)
                if error.isRateLimited {
                    retryDelay = 1
                } else {
                    retryDelay = min(retryDelay * 2, 30)
                }
            }
        }
    }

    private func loadOffset() -> Int64? {
        (try? stateStore.load())?.poller.offset
    }

    private func saveOffset(_ offset: Int64) {
        guard var state = try? stateStore.load() else {
            return
        }

        state.poller.offset = offset
        try? stateStore.save(state)
    }
}

private extension TelegramAPIError {
    var isRateLimited: Bool {
        if case .rateLimited = self {
            return true
        }
        return false
    }

    var isUnauthorized: Bool {
        switch self {
        case .http(status: 401, description: _),
             .botApi(errorCode: 401, description: _):
            return true
        case .http, .rateLimited, .decoding, .botApi, .transport:
            return false
        }
    }

    func retryDelay(defaultDelay: TimeInterval) -> TimeInterval {
        switch self {
        case .rateLimited(let retryAfterSeconds):
            return retryAfterSeconds
        case .http, .decoding, .botApi, .transport:
            return defaultDelay
        }
    }
}
