import Combine
import Foundation

@MainActor
final class TelegramService: ObservableObject {
    static let shared = TelegramService()

    private var settings: TelegramSettings
    private let tokenStore: TelegramTokenStoring
    private let stateStore: TelegramStateStoring
    private let authState: TelegramAuthControlling
    private let notificationCenter: NotificationCenter
    private let pollerFactory: (String) async -> TelegramPolling
    private let outboundObserverFactory: @MainActor (String, Int64) -> TelegramOutboundObserving
    private let inboundDispatcherFactory: @MainActor (String, TelegramStateStoring) -> TelegramInboundDispatching
    private let restartSweeperFactory: @MainActor (String, TelegramStateStoring) -> TelegramRestartSweeping
    private let activeSessionsProvider: @MainActor () async -> [SessionState]
    private let callbackGCFactory: @MainActor (String, TelegramStateStoring) -> TelegramCallbackGarbageCollecting
    private let callbackGCSleep: @Sendable (TimeInterval) async -> Void
    private let messagingClientFactory: @MainActor (String) -> TelegramMessagingClient

    @Published private(set) var diagnostics = TelegramDiagnosticsState()

    private var poller: TelegramPolling?
    private var pollerToken: String?
    private var inboundDispatcher: TelegramInboundDispatching?
    private var inboundToken: String?
    private var outboundObserver: TelegramOutboundObserving?
    private var outboundToken: String?
    private var outboundChatId: Int64?
    private var completedRestartSweepKey: String?
    private var callbackGCTask: Task<Void, Never>?
    private var callbackGCToken: String?
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
        outboundObserverFactory: @escaping @MainActor (String, Int64) -> TelegramOutboundObserving = TelegramService.makeDefaultOutboundObserver,
        inboundDispatcherFactory: @escaping @MainActor (String, TelegramStateStoring) -> TelegramInboundDispatching = TelegramService.makeDefaultInboundDispatcher,
        restartSweeperFactory: @escaping @MainActor (String, TelegramStateStoring) -> TelegramRestartSweeping = TelegramService.makeDefaultRestartSweeper,
        activeSessionsProvider: @escaping @MainActor () async -> [SessionState] = {
            SessionStore.shared.allSessions()
        },
        callbackGCFactory: @escaping @MainActor (String, TelegramStateStoring) -> TelegramCallbackGarbageCollecting = TelegramService.makeDefaultCallbackGC,
        callbackGCSleep: @escaping @Sendable (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        },
        messagingClientFactory: @escaping @MainActor (String) -> TelegramMessagingClient = { TelegramAPIClient(token: $0) }
    ) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.stateStore = stateStore
        self.authState = authState
        self.notificationCenter = notificationCenter
        self.pollerFactory = pollerFactory
        self.outboundObserverFactory = outboundObserverFactory
        self.inboundDispatcherFactory = inboundDispatcherFactory
        self.restartSweeperFactory = restartSweeperFactory
        self.activeSessionsProvider = activeSessionsProvider
        self.callbackGCFactory = callbackGCFactory
        self.callbackGCSleep = callbackGCSleep
        self.messagingClientFactory = messagingClientFactory
    }

    deinit {
        callbackGCTask?.cancel()
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
        inboundDispatcher = nil
        inboundToken = nil
        stopCallbackGC()
        stopOutboundObserver()
        Task {
            await existingPoller?.stop()
        }
    }

    func refresh() async {
        guard settings.masterEnabled,
              let token = loadedToken()
        else {
            await stopCurrentPoller()
            stopCallbackGC()
            stopOutboundObserver()
            refreshDiagnosticsInFlightCount()
            return
        }

        if pollerToken != token {
            await stopCurrentPoller()
        }

        ensureInboundDispatcher(token: token)
        if let chatId = authorizedChatId {
            await runRestartSweepIfNeeded(token: token, chatId: chatId)
            await ensureCallbackGC(token: token)
            ensureOutboundObserver(token: token, chatId: chatId)
        } else {
            stopCallbackGC()
            stopOutboundObserver()
        }

        guard poller == nil else {
            return
        }

        let newPoller = await pollerFactory(token)
        poller = newPoller
        pollerToken = token
        await newPoller.start(
            handler: { [weak self] update in
                await self?.handle(update)
            },
            diagnosticsHandler: { [weak self] event in
                await self?.recordPollerDiagnostics(event)
            }
        )
    }

    func beginPairing() async {
        await authState.openPairingWindow(timeout: 5 * 60)
        await refresh()
    }

    func sendTestNotification() async -> Result<Void, TelegramAPIError> {
        guard let token = loadedToken(), let chatId = authorizedChatId else {
            return .failure(.transport(TelegramL10n.string("Telegram.Diagnostics.NotReady")))
        }

        let client = messagingClientFactory(token)
        switch await client.sendMessage(
            chatId: chatId,
            text: TelegramL10n.string("Telegram.Diagnostics.TestMessage"),
            replyMarkup: nil,
            disableNotification: false
        ) {
        case .success:
            return .success(())
        case .failure(let error):
            diagnostics.lastError = error.diagnosticsDescription
            return .failure(error)
        }
    }

    private func stopCurrentPoller() async {
        let existingPoller = poller
        poller = nil
        pollerToken = nil
        inboundDispatcher = nil
        inboundToken = nil
        stopCallbackGC()
        await existingPoller?.stop()
        refreshDiagnosticsInFlightCount()
    }

    private func ensureInboundDispatcher(token: String) {
        if inboundToken != token {
            inboundDispatcher = nil
            inboundToken = nil
        }

        guard inboundDispatcher == nil else {
            return
        }

        inboundDispatcher = inboundDispatcherFactory(token, stateStore)
        inboundToken = token
    }

    private func runRestartSweepIfNeeded(token: String, chatId: Int64) async {
        let sweepKey = "\(token)|\(chatId)"
        guard completedRestartSweepKey != sweepKey else {
            return
        }

        let sweeper = restartSweeperFactory(token, stateStore)
        await sweeper.sweep(activeSessions: activeSessionsProvider())
        completedRestartSweepKey = sweepKey
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

    private func ensureCallbackGC(token: String) async {
        guard callbackGCToken != token else {
            return
        }

        stopCallbackGC()
        let collector = callbackGCFactory(token, stateStore)
        await collector.collect(now: Date())
        callbackGCToken = token
        callbackGCTask = Task { @MainActor [callbackGCSleep] in
            while !Task.isCancelled {
                await callbackGCSleep(60 * 60)
                guard !Task.isCancelled else {
                    return
                }
                await collector.collect(now: Date())
            }
        }
    }

    private func stopCallbackGC() {
        callbackGCTask?.cancel()
        callbackGCTask = nil
        callbackGCToken = nil
    }

    private func recordPollerDiagnostics(_ event: TelegramPollerDiagnosticsEvent) {
        switch event {
        case .success(let date):
            diagnostics.lastSuccessfulGetUpdatesAt = date
            diagnostics.lastError = nil
        case .failure(let error, _):
            diagnostics.lastError = error.diagnosticsDescription
        }
        refreshDiagnosticsInFlightCount()
    }

    private func refreshDiagnosticsInFlightCount() {
        diagnostics.inFlightMessageCount = ((try? stateStore.load())?.messages.count) ?? 0
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
        if update.callbackQuery != nil {
            await inboundDispatcher?.handle(update)
            return
        }

        guard let chatId = update.message?.chat?.id else {
            return
        }

        let decision = await authState.handleIncomingMessage(from: chatId)
        if case .captured = decision {
            await refresh()
        }
    }

    private static func makeDefaultOutboundObserver(token: String, chatId: Int64) -> TelegramOutboundObserving {
        TelegramOutboundObserver(
            chatId: chatId,
            client: TelegramAPIClient(token: token),
            actionHub: InterventionActionHub.shared
        )
    }

    private static func makeDefaultInboundDispatcher(
        token: String,
        stateStore: TelegramStateStoring
    ) -> TelegramInboundDispatching {
        TelegramInboundDispatcher(
            stateStore: stateStore,
            callbackRegistry: TelegramCallbackRegistry(stateStore: stateStore),
            client: TelegramAPIClient(token: token)
        )
    }

    private static func makeDefaultRestartSweeper(
        token: String,
        stateStore: TelegramStateStoring
    ) -> TelegramRestartSweeping {
        TelegramRestartSweeper(
            messageRegistry: TelegramMessageRegistry(stateStore: stateStore),
            callbackRegistry: TelegramCallbackRegistry(stateStore: stateStore),
            client: TelegramAPIClient(token: token)
        )
    }

    private static func makeDefaultCallbackGC(
        token: String,
        stateStore: TelegramStateStoring
    ) -> TelegramCallbackGarbageCollecting {
        TelegramCallbackGarbageCollector(
            messageRegistry: TelegramMessageRegistry(stateStore: stateStore),
            callbackRegistry: TelegramCallbackRegistry(stateStore: stateStore),
            client: TelegramAPIClient(token: token)
        )
    }
}

struct TelegramDiagnosticsState: Equatable {
    var lastSuccessfulGetUpdatesAt: Date?
    var lastError: String?
    var inFlightMessageCount: Int

    init(
        lastSuccessfulGetUpdatesAt: Date? = nil,
        lastError: String? = nil,
        inFlightMessageCount: Int = 0
    ) {
        self.lastSuccessfulGetUpdatesAt = lastSuccessfulGetUpdatesAt
        self.lastError = lastError
        self.inFlightMessageCount = inFlightMessageCount
    }
}

private extension TelegramAPIError {
    var diagnosticsDescription: String {
        switch self {
        case .http(let status, let description):
            return "HTTP \(status): \(description)"
        case .rateLimited(let retryAfterSeconds):
            return "Rate limited: retry after \(Int(retryAfterSeconds))s"
        case .decoding:
            return "Decoding failed"
        case .botApi(let errorCode, let description):
            return "Telegram \(errorCode): \(description)"
        case .transport(let message):
            return message
        }
    }
}
