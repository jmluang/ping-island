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
