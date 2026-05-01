import Foundation

actor TelegramLongPoller {
    private let client: TelegramUpdatesClient
    private let stateStore: TelegramStateStoring
    private let onInvalidToken: @Sendable () async -> Void

    private var pollingTask: Task<Void, Never>?

    init(
        client: TelegramUpdatesClient,
        stateStore: TelegramStateStoring = TelegramStateStore(),
        onInvalidToken: @escaping @Sendable () async -> Void = {}
    ) {
        self.client = client
        self.stateStore = stateStore
        self.onInvalidToken = onInvalidToken
    }

    var isRunning: Bool {
        pollingTask != nil
    }

    func start(handler: @escaping @Sendable (TelegramUpdate) async -> Void) {
        guard pollingTask == nil else {
            return
        }

        pollingTask = Task { [weak self] in
            await self?.poll(handler: handler)
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func poll(handler: @escaping @Sendable (TelegramUpdate) async -> Void) async {
        var offset = loadOffset()

        while !Task.isCancelled {
            let result = await client.getUpdates(
                offset: offset,
                timeoutSeconds: 30,
                allowedUpdates: ["message", "callback_query"]
            )

            switch result {
            case .success(let updates):
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
    var isUnauthorized: Bool {
        switch self {
        case .http(status: 401, description: _),
             .botApi(errorCode: 401, description: _):
            return true
        case .http, .rateLimited, .decoding, .botApi, .transport:
            return false
        }
    }
}
