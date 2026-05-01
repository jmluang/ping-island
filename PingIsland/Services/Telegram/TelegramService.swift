import Foundation

@MainActor
final class TelegramService {
    static let shared = TelegramService()

    private var settings: TelegramSettings
    private let tokenStore: TelegramTokenStoring
    private let stateStore: TelegramStateStoring
    private let notificationCenter: NotificationCenter
    private let pollerFactory: (String) async -> TelegramPolling

    private var poller: TelegramPolling?
    private var pollerToken: String?
    private var defaultsObserver: NSObjectProtocol?

    init(
        settings: TelegramSettings = TelegramSettings(),
        tokenStore: TelegramTokenStoring = TelegramTokenStore(),
        stateStore: TelegramStateStoring = TelegramStateStore(),
        notificationCenter: NotificationCenter = .default,
        pollerFactory: @escaping (String) async -> TelegramPolling = { token in
            TelegramLongPoller(client: TelegramAPIClient(token: token))
        }
    ) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.stateStore = stateStore
        self.notificationCenter = notificationCenter
        self.pollerFactory = pollerFactory
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
        Task {
            await existingPoller?.stop()
        }
    }

    func refresh() async {
        guard settings.masterEnabled,
              let token = loadedToken(),
              hasAuthorizedChat
        else {
            await stopCurrentPoller()
            return
        }

        if pollerToken != token {
            await stopCurrentPoller()
        }

        guard poller == nil else {
            return
        }

        let newPoller = await pollerFactory(token)
        poller = newPoller
        pollerToken = token
        await newPoller.start { _ in }
    }

    private func stopCurrentPoller() async {
        let existingPoller = poller
        poller = nil
        pollerToken = nil
        await existingPoller?.stop()
    }

    private func loadedToken() -> String? {
        guard let token = try? tokenStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            return nil
        }

        return token
    }

    private var hasAuthorizedChat: Bool {
        guard let state = try? stateStore.load() else {
            return false
        }

        return state.auth.chatId != nil
    }
}
