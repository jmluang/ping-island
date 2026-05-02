import Foundation

@MainActor
protocol TelegramRestartSweeping {
    func sweep(activeSessions: [SessionState]) async
}

@MainActor
final class TelegramRestartSweeper: TelegramRestartSweeping {
    private let messageRegistry: TelegramMessageRegistry
    private let callbackRegistry: TelegramCallbackRegistry
    private let client: TelegramMessagingClient
    private let rateLimitQueue: TelegramRateLimitQueue

    init(
        messageRegistry: TelegramMessageRegistry = TelegramMessageRegistry(),
        callbackRegistry: TelegramCallbackRegistry = TelegramCallbackRegistry(),
        client: TelegramMessagingClient,
        rateLimitQueue: TelegramRateLimitQueue = TelegramRateLimitQueue()
    ) {
        self.messageRegistry = messageRegistry
        self.callbackRegistry = callbackRegistry
        self.client = client
        self.rateLimitQueue = rateLimitQueue
    }

    func sweep(activeSessions: [SessionState]) async {
        let activeKeys = Set(activeSessions.compactMap { session -> String? in
            guard let renderable = TelegramAttentionPayload.renderable(for: session) else {
                return nil
            }
            return InterventionKey.make(sessionId: session.sessionId, interventionId: renderable.id)
        })

        guard let storedMessages = try? await messageRegistry.all() else {
            return
        }

        for (key, entry) in storedMessages where !activeKeys.contains(key) {
            await rateLimitQueue.enqueue(chatId: entry.chatId) { [client] in
                switch await client.editMessageText(
                    chatId: entry.chatId,
                    messageId: entry.messageId,
                    text: TelegramL10n.string("Telegram.Message.RestartedConfirmInNotch"),
                    replyMarkup: nil
                ) {
                case .success:
                    return .success(())
                case .failure(let error):
                    return .failure(error)
                }
            }

            guard let ids = InterventionKey.parse(key) else {
                continue
            }
            try? await messageRegistry.remove(sessionId: ids.sessionId, interventionId: ids.interventionId)
            _ = try? await callbackRegistry.remove(sessionId: ids.sessionId, interventionId: ids.interventionId)
        }
    }
}
