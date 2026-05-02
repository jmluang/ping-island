import Foundation

@MainActor
protocol TelegramCallbackGarbageCollecting {
    func collect(now: Date) async
}

@MainActor
final class TelegramCallbackGarbageCollector: TelegramCallbackGarbageCollecting {
    private let messageRegistry: TelegramMessageRegistry
    private let callbackRegistry: TelegramCallbackRegistry
    private let client: TelegramMessagingClient
    private let rateLimitQueue: TelegramRateLimitQueue
    private let maxAge: TimeInterval

    init(
        messageRegistry: TelegramMessageRegistry = TelegramMessageRegistry(),
        callbackRegistry: TelegramCallbackRegistry = TelegramCallbackRegistry(),
        client: TelegramMessagingClient,
        rateLimitQueue: TelegramRateLimitQueue = TelegramRateLimitQueue(),
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        self.messageRegistry = messageRegistry
        self.callbackRegistry = callbackRegistry
        self.client = client
        self.rateLimitQueue = rateLimitQueue
        self.maxAge = maxAge
    }

    func collect(now: Date) async {
        guard let callbacks = try? await callbackRegistry.all() else {
            return
        }

        let expiredKeys = Set(callbacks.values.compactMap { resolution -> String? in
            guard now.timeIntervalSince(resolution.issuedAt) >= maxAge else {
                return nil
            }
            return InterventionKey.make(
                sessionId: resolution.sessionId,
                interventionId: resolution.interventionId
            )
        })

        for key in expiredKeys {
            guard let ids = InterventionKey.parse(key) else {
                continue
            }

            if let entry = try? await messageRegistry.entry(
                sessionId: ids.sessionId,
                interventionId: ids.interventionId
            ) {
                await rateLimitQueue.enqueue(chatId: entry.chatId) { [client] in
                    switch await client.editMessageText(
                        chatId: entry.chatId,
                        messageId: entry.messageId,
                        text: "⏱ Expired",
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
    }
}
