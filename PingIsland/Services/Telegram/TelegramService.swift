import Foundation

@MainActor
final class TelegramService {
    static let shared = TelegramService()

    private var settings: TelegramSettings
    private let tokenStore: TelegramTokenStoring
    private let stateStore: TelegramStateStoring
    private let authState: TelegramAuthControlling
    private let notificationCenter: NotificationCenter
    private let pollerFactory: (String) async -> TelegramPolling
    private let outboundObserverFactory: @MainActor (String, Int64) -> TelegramOutboundObserving

    private var poller: TelegramPolling?
    private var pollerToken: String?
    private var outboundObserver: TelegramOutboundObserving?
    private var outboundToken: String?
    private var outboundChatId: Int64?
    private var defaultsObserver: NSObjectProtocol?

    init(
        settings: TelegramSettings = TelegramSettings(),
        tokenStore: TelegramTokenStoring = TelegramTokenStore(),
        stateStore: TelegramStateStoring = TelegramStateStore(),
        authState: TelegramAuthControlling = TelegramAuthState(),
        notificationCenter: NotificationCenter = .default,
        pollerFactory: @escaping (String) async -> TelegramPolling = { token in
            TelegramLongPoller(client: TelegramAPIClient(token: token))
        },
        outboundObserverFactory: @escaping @MainActor (String, Int64) -> TelegramOutboundObserving = TelegramService.makeDefaultOutboundObserver
    ) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.stateStore = stateStore
        self.authState = authState
        self.notificationCenter = notificationCenter
        self.pollerFactory = pollerFactory
        self.outboundObserverFactory = outboundObserverFactory
    }

    func start() {
        guard defaultsObserver == nil else {
            return
        }

        defaultsObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }

        Task { @MainActor in
            await refresh()
        }
    }

    func stop() {
        if let defaultsObserver {
            notificationCenter.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }

        let existingPoller = poller
        poller = nil
        pollerToken = nil
        stopOutboundObserver()
        Task {
            await existingPoller?.stop()
        }
    }

    func refresh() async {
        guard settings.masterEnabled,
              let token = loadedToken(),
              let chatId = authorizedChatId
        else {
            await stopCurrentPoller()
            stopOutboundObserver()
            return
        }

        if pollerToken != token {
            await stopCurrentPoller()
        }

        ensureOutboundObserver(token: token, chatId: chatId)

        guard poller == nil else {
            return
        }

        let newPoller = await pollerFactory(token)
        poller = newPoller
        pollerToken = token
        await newPoller.start { [weak self] update in
            await self?.handle(update)
        }
    }

    func beginPairing() async {
        await authState.openPairingWindow(timeout: 5 * 60)
    }

    private func stopCurrentPoller() async {
        let existingPoller = poller
        poller = nil
        pollerToken = nil
        await existingPoller?.stop()
    }

    private func ensureOutboundObserver(token: String, chatId: Int64) {
        if outboundToken != token || outboundChatId != chatId {
            stopOutboundObserver()
        }

        guard outboundObserver == nil else {
            return
        }

        let observer = outboundObserverFactory(token, chatId)
        outboundObserver = observer
        outboundToken = token
        outboundChatId = chatId
        observer.start(publisher: SessionStore.shared.sessionsPublisher)
    }

    private func stopOutboundObserver() {
        outboundObserver?.stop()
        outboundObserver = nil
        outboundToken = nil
        outboundChatId = nil
    }

    private func loadedToken() -> String? {
        guard let token = try? tokenStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            return nil
        }

        return token
    }

    private var authorizedChatId: Int64? {
        guard let state = try? stateStore.load() else {
            return nil
        }

        return state.auth.chatId
    }

    private func handle(_ update: TelegramUpdate) async {
        guard let chatId = update.message?.chat?.id else {
            return
        }

        _ = await authState.handleIncomingMessage(from: chatId)
    }

    private static func makeDefaultOutboundObserver(token: String, chatId: Int64) -> TelegramOutboundObserving {
        TelegramOutboundObserver(
            chatId: chatId,
            client: TelegramAPIClient(token: token),
            actionHub: InterventionActionHub.shared
        )
    }
}
