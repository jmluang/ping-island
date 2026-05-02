import Combine
import Foundation
import Security

@MainActor
protocol TelegramOutboundObserving: AnyObject {
    func start(publisher: AnyPublisher<[SessionState], Never>)
    func stop()
}

@MainActor
final class TelegramOutboundObserver {
    private let chatId: Int64
    private let client: TelegramMessagingClient
    private let messageRegistry: TelegramMessageRegistry
    private let callbackRegistry: TelegramCallbackRegistry
    private let rateLimitQueue: TelegramRateLimitQueue
    private let now: () -> Date
    private let timeFormatter: (Date) -> String
    private let tokenProvider: TelegramMessageRenderer.TokenProvider
    private let recentResponseTTL: TimeInterval
    private let categoryEnabled: (TelegramEventCategory) -> Bool

    private var lastKeys: Set<String> = []
    private var recentResponses: [String: Date] = [:]
    private var hasPrimedStatusTransitions = false
    private var previousCompletedIds: Set<String> = []
    private var previousErrorIds: Set<String> = []
    private var previousLimitIds: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    init(
        chatId: Int64,
        client: TelegramMessagingClient,
        messageRegistry: TelegramMessageRegistry = TelegramMessageRegistry(),
        callbackRegistry: TelegramCallbackRegistry = TelegramCallbackRegistry(),
        rateLimitQueue: TelegramRateLimitQueue = TelegramRateLimitQueue(),
        now: @escaping () -> Date = Date.init,
        timeFormatter: @escaping (Date) -> String = TelegramOutboundTimeFormatter.makeTimeString,
        tokenProvider: @escaping TelegramMessageRenderer.TokenProvider = { _ in
            TelegramCallbackTokenGenerator.makeToken()
        },
        recentResponseTTL: TimeInterval = 1.0,
        categoryEnabled: @escaping (TelegramEventCategory) -> Bool = { TelegramSettings().isEnabled(for: $0) },
        actionHub: InterventionActionHub? = nil
    ) {
        self.chatId = chatId
        self.client = client
        self.messageRegistry = messageRegistry
        self.callbackRegistry = callbackRegistry
        self.rateLimitQueue = rateLimitQueue
        self.now = now
        self.timeFormatter = timeFormatter
        self.tokenProvider = tokenProvider
        self.recentResponseTTL = recentResponseTTL
        self.categoryEnabled = categoryEnabled

        actionHub?.responded
            .sink { [weak self] response in
                self?.recordResponse(response)
            }
            .store(in: &cancellables)
    }

    func start(publisher: AnyPublisher<[SessionState], Never>) {
        publisher
            .sink { [weak self] sessions in
                Task { @MainActor in
                    await self?.processSnapshot(sessions)
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        lastKeys.removeAll()
        recentResponses.removeAll()
        hasPrimedStatusTransitions = false
        previousCompletedIds.removeAll()
        previousErrorIds.removeAll()
        previousLimitIds.removeAll()
    }

    func recordResponse(_ response: InterventionResponse) {
        recentResponses[InterventionKey.make(
            sessionId: response.sessionId,
            interventionId: response.interventionId
        )] = response.timestamp
        Task { @MainActor in
            await finalizeResponse(response)
        }
    }

    func finalizeResponse(_ response: InterventionResponse) async {
        let key = InterventionKey.make(
            sessionId: response.sessionId,
            interventionId: response.interventionId
        )
        recentResponses[key] = response.timestamp

        guard let entry = try? await messageRegistry.entry(
            sessionId: response.sessionId,
            interventionId: response.interventionId
        ) else {
            return
        }

        await rateLimitQueue.enqueue(chatId: entry.chatId) { [client] in
            switch await client.editMessageText(
                chatId: entry.chatId,
                messageId: entry.messageId,
                text: self.finalText(for: response),
                replyMarkup: nil
            ) {
            case .success:
                return .success(())
            case .failure(let error):
                return .failure(error)
            }
        }

        try? await messageRegistry.remove(
            sessionId: response.sessionId,
            interventionId: response.interventionId
        )
        _ = try? await callbackRegistry.remove(
            sessionId: response.sessionId,
            interventionId: response.interventionId
        )
    }

    func processSnapshot(_ sessions: [SessionState]) async {
        pruneRecentResponses()
        await emitStatusNotifications(from: sessions)

        let renderables = Dictionary(uniqueKeysWithValues: sessions.compactMap { session -> (String, RenderableAttention)? in
            guard let renderable = TelegramAttentionPayload.renderable(for: session) else {
                return nil
            }

            let key = InterventionKey.make(sessionId: session.sessionId, interventionId: renderable.id)
            return (key, RenderableAttention(
                session: session,
                interventionId: renderable.id,
                payload: renderable.payload,
                category: renderable.payload.category
            ))
        })

        let currentKeys = Set(renderables.keys)
        let removedKeys = lastKeys.subtracting(currentKeys)

        for key in currentKeys {
            guard let renderable = renderables[key] else {
                continue
            }
            guard categoryEnabled(renderable.category) else {
                continue
            }
            await send(renderable)
        }

        for key in removedKeys {
            await markWithdrawnIfNeeded(key: key)
        }

        lastKeys = currentKeys
    }

    private func emitStatusNotifications(from sessions: [SessionState]) async {
        let completedSessions = sessions.filter(isCompletedReadySession)
        let completedIds = Set(completedSessions.map(\.stableId))
        let errorEvents = sessions.flatMap { session in
            session.completedErrorToolIDs.map { toolId in
                StatusErrorEvent(
                    id: "\(session.sessionId):\(toolId)",
                    session: session,
                    toolId: toolId
                )
            }
        }
        let errorIds = Set(errorEvents.map(\.id))
        let limitSessions = sessions.filter { $0.phase == .compacting }
        let limitIds = Set(limitSessions.map(\.stableId))

        guard hasPrimedStatusTransitions else {
            hasPrimedStatusTransitions = true
            previousCompletedIds = completedIds
            previousErrorIds = errorIds
            previousLimitIds = limitIds
            return
        }

        if categoryEnabled(.error) {
            for event in errorEvents where !previousErrorIds.contains(event.id) {
                await sendStatus(session: event.session, payload: .error(toolId: event.toolId))
            }
        }

        if categoryEnabled(.limit) {
            for session in limitSessions where !previousLimitIds.contains(session.stableId) {
                await sendStatus(session: session, payload: .limit)
            }
        }

        if categoryEnabled(.completion) {
            for session in completedSessions where !previousCompletedIds.contains(session.stableId) {
                await sendStatus(session: session, payload: .completion)
            }
        }

        previousCompletedIds = completedIds
        previousErrorIds = errorIds
        previousLimitIds = limitIds
    }

    private func sendStatus(session: SessionState, payload: TelegramAttentionPayload) async {
        let rendered = TelegramMessageRenderer.render(
            session: session,
            payload: payload,
            issuedAt: now(),
            tokenProvider: tokenProvider
        )

        await rateLimitQueue.enqueue(chatId: chatId) { [chatId, client] in
            switch await client.sendMessage(
                chatId: chatId,
                text: rendered.text,
                replyMarkup: rendered.replyMarkup,
                disableNotification: false
            ) {
            case .success:
                return .success(())
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    private func isCompletedReadySession(_ session: SessionState) -> Bool {
        guard session.phase == .waitingForInput else { return false }
        guard session.intervention == nil else { return false }

        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant:
                return true
            case .user, .thinking, .toolCall, .interrupted:
                return false
            }
        }

        return session.lastMessageRole == "assistant"
    }

    private func send(_ renderable: RenderableAttention) async {
        guard (try? await messageRegistry.entry(
            sessionId: renderable.session.sessionId,
            interventionId: renderable.interventionId
        )) == nil else {
            return
        }

        let rendered = TelegramMessageRenderer.render(
            session: renderable.session,
            payload: renderable.payload,
            issuedAt: now(),
            tokenProvider: tokenProvider
        )

        await rateLimitQueue.enqueue(chatId: chatId) { [chatId, client] in
            switch await client.sendMessage(
                chatId: chatId,
                text: rendered.text,
                replyMarkup: rendered.replyMarkup,
                disableNotification: false
            ) {
            case .success(let message):
                do {
                    try await self.messageRegistry.upsert(
                        .init(chatId: chatId, messageId: message.messageId, sentAt: self.now()),
                        sessionId: renderable.session.sessionId,
                        interventionId: renderable.interventionId
                    )
                    try await self.callbackRegistry.upsert(rendered.callbackResolutions)
                } catch {
                    return .failure(.transport(String(describing: error)))
                }
                return .success(())
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    private func markWithdrawnIfNeeded(key: String) async {
        guard let ids = splitKey(key) else {
            return
        }

        let isRecentResponse = recentResponses[key].map {
            now().timeIntervalSince($0) <= recentResponseTTL
        } ?? false

        if !isRecentResponse,
           let entry = try? await messageRegistry.entry(sessionId: ids.sessionId, interventionId: ids.interventionId) {
            await rateLimitQueue.enqueue(chatId: entry.chatId) { [client] in
                switch await client.editMessageText(
                    chatId: entry.chatId,
                    messageId: entry.messageId,
                    text: TelegramL10n.string("Telegram.Message.RequestWithdrawn"),
                    replyMarkup: nil
                ) {
                case .success:
                    return .success(())
                case .failure(let error):
                    return .failure(error)
                }
            }
        }

        try? await messageRegistry.remove(sessionId: ids.sessionId, interventionId: ids.interventionId)
        _ = try? await callbackRegistry.remove(sessionId: ids.sessionId, interventionId: ids.interventionId)
    }

    private func finalText(for response: InterventionResponse) -> String {
        let decision = decisionText(for: response.decision)
        let time = timeFormatter(response.timestamp)

        switch response.source {
        case .mac:
            return TelegramL10n.format("Telegram.Message.FinalMac", decision, time)
        case .telegram:
            return TelegramL10n.format("Telegram.Message.FinalTelegram", decision, time)
        }
    }

    private func decisionText(for decision: InterventionResponse.Decision) -> String {
        switch decision {
        case .approveOnce:
            return TelegramL10n.string("Telegram.Message.Decision.ApprovedOnce")
        case .approveForSession:
            return TelegramL10n.string("Telegram.Message.Decision.ApprovedForSession")
        case .deny:
            return TelegramL10n.string("Telegram.Message.Decision.Denied")
        case .answer:
            return TelegramL10n.string("Telegram.Message.Decision.Answered")
        }
    }

    private func pruneRecentResponses() {
        let cutoff = now().addingTimeInterval(-recentResponseTTL)
        recentResponses = recentResponses.filter { $0.value >= cutoff }
    }

    private func splitKey(_ key: String) -> (sessionId: String, interventionId: String)? {
        InterventionKey.parse(key)
    }

    private struct RenderableAttention {
        let session: SessionState
        let interventionId: String
        let payload: TelegramAttentionPayload
        let category: TelegramEventCategory
    }

    private struct StatusErrorEvent {
        let id: String
        let session: SessionState
        let toolId: String
    }
}

extension TelegramOutboundObserver: TelegramOutboundObserving {}

enum TelegramCallbackTokenGenerator {
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum TelegramOutboundTimeFormatter {
    static func makeTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
