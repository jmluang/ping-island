import Foundation

protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

enum TelegramAPIError: Error, Equatable {
    case http(status: Int, description: String)
    case decoding
    case botApi(errorCode: Int, description: String)
    case transport(String)
}

struct TelegramUser: Codable, Equatable {
    let id: Int64
    let isBot: Bool?
    let username: String?

    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case username
    }
}

struct TelegramMessage: Codable, Equatable {
    let messageId: Int64
    let date: Int

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case date
    }
}

struct TelegramInlineKeyboardButton: Encodable, Equatable {
    let text: String
    let callbackData: String

    enum CodingKeys: String, CodingKey {
        case text
        case callbackData = "callback_data"
    }
}

struct TelegramInlineKeyboardMarkup: Encodable, Equatable {
    let inlineKeyboard: [[TelegramInlineKeyboardButton]]

    enum CodingKeys: String, CodingKey {
        case inlineKeyboard = "inline_keyboard"
    }
}

private struct TelegramEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
    let errorCode: Int?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case result
        case description
        case errorCode = "error_code"
    }
}

final class TelegramAPIClient {
    private let token: String
    private let session: URLSessionProtocol
    private let baseURL = URL(string: "https://api.telegram.org")!

    init(token: String, session: URLSessionProtocol = URLSession.shared) {
        self.token = token
        self.session = session
    }

    func getMe() async -> Result<TelegramUser, TelegramAPIError> {
        await call("getMe", payload: Optional<EmptyPayload>.none)
    }

    func sendMessage(
        chatId: Int64,
        text: String,
        replyMarkup: TelegramInlineKeyboardMarkup? = nil,
        disableNotification: Bool = false
    ) async -> Result<TelegramMessage, TelegramAPIError> {
        struct Payload: Encodable {
            let chatId: Int64
            let text: String
            let replyMarkup: TelegramInlineKeyboardMarkup?
            let disableNotification: Bool?

            enum CodingKeys: String, CodingKey {
                case chatId = "chat_id"
                case text
                case replyMarkup = "reply_markup"
                case disableNotification = "disable_notification"
            }
        }

        return await call("sendMessage", payload: Payload(
            chatId: chatId,
            text: text,
            replyMarkup: replyMarkup,
            disableNotification: disableNotification ? true : nil
        ))
    }

    func editMessageText(
        chatId: Int64,
        messageId: Int64,
        text: String,
        replyMarkup: TelegramInlineKeyboardMarkup? = nil
    ) async -> Result<TelegramMessage, TelegramAPIError> {
        struct Payload: Encodable {
            let chatId: Int64
            let messageId: Int64
            let text: String
            let replyMarkup: TelegramInlineKeyboardMarkup?

            enum CodingKeys: String, CodingKey {
                case chatId = "chat_id"
                case messageId = "message_id"
                case text
                case replyMarkup = "reply_markup"
            }
        }

        return await call("editMessageText", payload: Payload(
            chatId: chatId,
            messageId: messageId,
            text: text,
            replyMarkup: replyMarkup
        ))
    }

    func answerCallbackQuery(
        callbackQueryId: String,
        text: String? = nil
    ) async -> Result<Bool, TelegramAPIError> {
        struct Payload: Encodable {
            let callbackQueryId: String
            let text: String?

            enum CodingKeys: String, CodingKey {
                case callbackQueryId = "callback_query_id"
                case text
            }
        }

        return await call("answerCallbackQuery", payload: Payload(
            callbackQueryId: callbackQueryId,
            text: text
        ))
    }

    private struct EmptyPayload: Encodable {}

    private func call<Payload: Encodable, Response: Decodable>(
        _ method: String,
        payload: Payload?
    ) async -> Result<Response, TelegramAPIError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("bot\(token)/\(method)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let payload {
            do {
                request.httpBody = try JSONEncoder().encode(payload)
            } catch {
                return .failure(.transport("encode failed"))
            }
        }

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            return .failure(.transport("non-http response"))
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            return .failure(.http(status: httpResponse.statusCode, description: String(data: data, encoding: .utf8) ?? ""))
        }

        guard let envelope = try? JSONDecoder().decode(TelegramEnvelope<Response>.self, from: data) else {
            return .failure(.decoding)
        }

        guard envelope.ok, let result = envelope.result else {
            return .failure(.botApi(
                errorCode: envelope.errorCode ?? httpResponse.statusCode,
                description: envelope.description ?? "unknown"
            ))
        }

        return .success(result)
    }
}
