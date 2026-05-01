import Foundation

actor TelegramCallbackRegistry {
    private let stateStore: TelegramStateStoring

    init(stateStore: TelegramStateStoring = TelegramStateStore()) {
        self.stateStore = stateStore
    }

    func resolve(token: String) throws -> TelegramPersistentState.CallbackResolution? {
        let state = try stateStore.load()
        return state.callbacks[token]
    }

    func upsert(_ resolutions: [String: TelegramPersistentState.CallbackResolution]) throws {
        guard !resolutions.isEmpty else { return }

        var state = try stateStore.load()
        for (token, resolution) in resolutions {
            state.callbacks[token] = resolution
        }
        try stateStore.save(state)
    }

    func remove(tokens: Set<String>) throws {
        guard !tokens.isEmpty else { return }

        var state = try stateStore.load()
        for token in tokens {
            state.callbacks.removeValue(forKey: token)
        }
        try stateStore.save(state)
    }
}
