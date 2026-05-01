import Foundation

protocol TelegramAuthControlling: Sendable {
    func openPairingWindow(timeout: TimeInterval) async
    func handleIncomingMessage(from incomingChatId: Int64) async -> TelegramAuthState.AuthDecision
}

actor TelegramAuthState: TelegramAuthControlling {
    enum AuthDecision: Equatable {
        case alreadyPaired
        case captured(chatId: Int64)
        case dropped
    }

    private let stateStore: TelegramStateStoring
    private let now: @Sendable () async -> Date

    private var chatId: Int64?
    private var pairingDeadline: Date?

    init(
        stateStore: TelegramStateStoring = TelegramStateStore(),
        now: @escaping @Sendable () async -> Date = { Date() }
    ) {
        self.stateStore = stateStore
        self.now = now
        self.chatId = Self.loadChatId(from: stateStore)
    }

    var isPairingOpen: Bool {
        get async {
            await pairingWindowIsOpen()
        }
    }

    func openPairingWindow(timeout: TimeInterval = 5 * 60) async {
        pairingDeadline = await now().addingTimeInterval(timeout)
    }

    func closePairingWindow() {
        pairingDeadline = nil
    }

    func handleIncomingMessage(from incomingChatId: Int64) async -> AuthDecision {
        if chatId != nil {
            return .alreadyPaired
        }

        guard await pairingWindowIsOpen() else {
            return .dropped
        }

        guard saveChatId(incomingChatId) else {
            closePairingWindow()
            return .dropped
        }

        chatId = incomingChatId
        closePairingWindow()
        return .captured(chatId: incomingChatId)
    }

    private func pairingWindowIsOpen() async -> Bool {
        guard let pairingDeadline else {
            return false
        }

        if await now() < pairingDeadline {
            return true
        }

        self.pairingDeadline = nil
        return false
    }

    private func saveChatId(_ chatId: Int64) -> Bool {
        guard var state = try? stateStore.load() else {
            return false
        }

        state.auth.chatId = chatId

        do {
            try stateStore.save(state)
            return true
        } catch {
            return false
        }
    }

    private static func loadChatId(from stateStore: TelegramStateStoring) -> Int64? {
        guard let state = try? stateStore.load() else {
            return nil
        }

        return state.auth.chatId
    }
}
