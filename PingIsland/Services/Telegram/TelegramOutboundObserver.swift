import Combine
import Foundation
import Security

@MainActor
final class TelegramOutboundObserver {
    private let chatId: Int64
    private let client: TelegramMessagingClient
    private let messageRegistry: TelegramMessageRegistry
    private let callbackRegistry: TelegramCallbackRegistry
    private let rateLimitQueue: TelegramRateLimitQueue
    private let now: () -> Date
    private let tokenProvider: TelegramMessageRenderer.TokenProvider
    private let recentResponseTTL: TimeInterval

    private var lastKeys: Set<String> = []
    private var recentResponses: [String: Date] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(
        chatId: Int64,
        client: TelegramMessagingClient,
        messageRegistry: TelegramMessageRegistry = TelegramMessageRegistry(),
        callbackRegistry: TelegramCallbackRegistry = TelegramCallbackRegistry(),
        rateLimitQueue: TelegramRateLimitQueue = TelegramRateLimitQueue(),
        now: @escaping () -> Date = Date.init,
        tokenProvider: @escaping TelegramMessageRenderer.TokenProvider = { _ in
            TelegramCallbackTokenGenerator.makeToken()
        },
        recentResponseTTL: TimeInterval = 1.0,
        actionHub: InterventionActionHub? = nil
    ) {
        self.chatId = chatId
        self.client = client
        self.messageRegistry = messageRegistry
        self.callbackRegistry = callbackRegistry
        self.rateLimitQueue = rateLimitQueue
        self.now = now
        self.tokenProvider = tokenProvider
        self.recentResponseTTL = recentResponseTTL

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
    }

    func recordResponse(_ response: InterventionResponse) {
        recentResponses[InterventionKey.make(
            sessionId: response.sessionId,
            interventionId: response.interventionId
        )] = response.timestamp
    }

    func processSnapshot(_ sessions: [SessionState]) async {
        pruneRecentResponses()

        let renderables = Dictionary(uniqueKeysWithValues: sessions.compactMap { session -> (String, RenderableAttention)? in
            guard let payload = TelegramAttentionPayload.approval(for: session),
                  case .approval(let id, _, _) = payload
            else {
                return nil
            }

            let key = InterventionKey.make(sessionId: session.sessionId, interventionId: id)
            return (key, RenderableAttention(session: session, interventionId: id, payload: payload))
        })

        let currentKeys = Set(renderables.keys)
        let removedKeys = lastKeys.subtracting(currentKeys)

        for key in currentKeys.subtracting(lastKeys) {
            guard let renderable = renderables[key] else {
                continue
            }
            await send(renderable)
        }

        for key in removedKeys {
            await markWithdrawnIfNeeded(key: key)
        }

        lastKeys = currentKeys
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
                    text: "⏱ Request withdrawn",
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

    private func pruneRecentResponses() {
        let cutoff = now().addingTimeInterval(-recentResponseTTL)
        recentResponses = recentResponses.filter { $0.value >= cutoff }
    }

    private func splitKey(_ key: String) -> (sessionId: String, interventionId: String)? {
        guard let separator = key.firstIndex(of: "|") else {
            return nil
        }

        let sessionId = String(key[..<separator])
        let interventionId = String(key[key.index(after: separator)...])
        guard !sessionId.isEmpty, !interventionId.isEmpty else {
            return nil
        }
        return (sessionId, interventionId)
    }

    private struct RenderableAttention {
        let session: SessionState
        let interventionId: String
        let payload: TelegramAttentionPayload
    }
}

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
