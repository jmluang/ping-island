import Foundation

actor TelegramMessageRegistry {
    private let stateStore: TelegramStateStoring

    init(stateStore: TelegramStateStoring = TelegramStateStore()) {
        self.stateStore = stateStore
    }

    func entry(sessionId: String, interventionId: String) throws -> TelegramPersistentState.MessageEntry? {
        let state = try stateStore.load()
        return state.messages[InterventionKey.make(sessionId: sessionId, interventionId: interventionId)]
    }

    func all() throws -> [String: TelegramPersistentState.MessageEntry] {
        try stateStore.load().messages
    }

    func upsert(
        _ entry: TelegramPersistentState.MessageEntry,
        sessionId: String,
        interventionId: String
    ) throws {
        var state = try stateStore.load()
        state.messages[InterventionKey.make(sessionId: sessionId, interventionId: interventionId)] = entry
        try stateStore.save(state)
    }

    func remove(sessionId: String, interventionId: String) throws {
        var state = try stateStore.load()
        state.messages.removeValue(forKey: InterventionKey.make(sessionId: sessionId, interventionId: interventionId))
        try stateStore.save(state)
    }
}
