import Foundation

@MainActor
protocol TelegramInboundActionDispatching: AnyObject {
    func approvePermission(
        sessionId: String,
        forSession: Bool,
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError>

    func denyPermission(
        sessionId: String,
        reason: String?,
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError>

    func answerIntervention(
        sessionId: String,
        answers: [String: [String]],
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError>
}

extension InterventionActionHub: TelegramInboundActionDispatching {}

protocol TelegramInboundDispatching {
    func handle(_ update: TelegramUpdate) async
}

@MainActor
final class TelegramInboundDispatcher {
    private let stateStore: TelegramStateStoring
    private let callbackRegistry: TelegramCallbackRegistry
    private let client: TelegramMessagingClient
    private let hub: TelegramInboundActionDispatching

    init(
        stateStore: TelegramStateStoring = TelegramStateStore(),
        callbackRegistry: TelegramCallbackRegistry = TelegramCallbackRegistry(),
        client: TelegramMessagingClient,
        hub: TelegramInboundActionDispatching? = nil
    ) {
        self.stateStore = stateStore
        self.callbackRegistry = callbackRegistry
        self.client = client
        self.hub = hub ?? InterventionActionHub.shared
    }

    func handle(_ update: TelegramUpdate) async {
        guard let callbackQuery = update.callbackQuery,
              isAuthorized(callbackQuery),
              let message = callbackQuery.message,
              let chatId = message.chat?.id,
              let data = callbackQuery.data,
              let token = parseToken(from: data)
        else {
            return
        }

        guard let resolution = try? await callbackRegistry.resolve(token: token) else {
            await answer(callbackQuery, text: TelegramL10n.string("Telegram.Message.AlreadyHandled"))
            await edit(message: message, chatId: chatId, text: TelegramL10n.string("Telegram.Message.AlreadyHandled"))
            return
        }

        let result = await dispatch(resolution)
        switch result {
        case .success:
            await answer(callbackQuery, text: TelegramL10n.string("Telegram.Message.CallbackAccepted"))
            return
        case .failure(.dispatcherUnavailable):
            await answer(callbackQuery, text: TelegramL10n.string("Telegram.Message.MacNotOnline"))
            await edit(message: message, chatId: chatId, text: TelegramL10n.string("Telegram.Message.MacNotOnline"))
        case .failure(.actionNotHandled):
            await answer(callbackQuery, text: TelegramL10n.string("Telegram.Message.AlreadyHandled"))
            await edit(message: message, chatId: chatId, text: TelegramL10n.string("Telegram.Message.AlreadyHandled"))
        }
    }

    private func isAuthorized(_ callbackQuery: TelegramCallbackQuery) -> Bool {
        guard let authorizedChatId = (try? stateStore.load())?.auth.chatId else {
            return false
        }

        return callbackQuery.from.id == authorizedChatId
    }

    private func parseToken(from callbackData: String) -> String? {
        let parts = callbackData.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1", !parts[1].isEmpty else {
            return nil
        }
        return String(parts[1])
    }

    private func dispatch(
        _ resolution: TelegramPersistentState.CallbackResolution
    ) async -> Result<Void, InterventionActionDispatchError> {
        switch resolution.action {
        case .allowOnce:
            return await hub.approvePermission(
                sessionId: resolution.sessionId,
                forSession: false,
                source: .telegram
            )
        case .allowSession:
            return await hub.approvePermission(
                sessionId: resolution.sessionId,
                forSession: true,
                source: .telegram
            )
        case .deny:
            return await hub.denyPermission(
                sessionId: resolution.sessionId,
                reason: nil,
                source: .telegram
            )
        case .answerOption(let questionId, let optionTitle):
            return await hub.answerIntervention(
                sessionId: resolution.sessionId,
                answers: [questionId: [optionTitle]],
                source: .telegram
            )
        }
    }

    private func edit(message: TelegramMessage, chatId: Int64, text: String) async {
        _ = await client.editMessageText(
            chatId: chatId,
            messageId: message.messageId,
            text: text,
            replyMarkup: nil
        )
    }

    private func answer(_ callbackQuery: TelegramCallbackQuery, text: String) async {
        _ = await client.answerCallbackQuery(callbackQueryId: callbackQuery.id, text: text)
    }
}

extension TelegramInboundDispatcher: TelegramInboundDispatching {}
