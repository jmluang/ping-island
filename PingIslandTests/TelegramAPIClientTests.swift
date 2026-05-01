import XCTest
@testable import Ping_Island

final class TelegramAPIClientTests: XCTestCase {
    func testGetMeReturnsUsername() async throws {
        let session = FakeURLSession()
        session.responses["/getMe"] = .success(
            body: #"{"ok":true,"result":{"id":123,"is_bot":true,"username":"my_bot"}}"#,
            status: 200
        )
        let client = TelegramAPIClient(token: "TKN", session: session)

        let me = try await client.getMe().get()

        XCTAssertEqual(me.username, "my_bot")
        XCTAssertEqual(me.id, 123)
        XCTAssertEqual(session.recordedRequests.first?.url?.path, "/botTKN/getMe")
    }

    func testSendMessagePostsCorrectBodyAndDecodesMessageId() async throws {
        let session = FakeURLSession()
        session.responses["/sendMessage"] = .success(
            body: #"{"ok":true,"result":{"message_id":42,"date":0,"chat":{"id":7,"type":"private"}}}"#,
            status: 200
        )
        let client = TelegramAPIClient(token: "TKN", session: session)

        let message = try await client.sendMessage(
            chatId: 7,
            text: "hello",
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [[
                .init(text: "Allow Once", callbackData: "v1|abc|allow_once")
            ]])
        ).get()

        XCTAssertEqual(message.messageId, 42)
        let request = try XCTUnwrap(session.recordedRequests.first)
        XCTAssertEqual(request.url?.path, "/botTKN/sendMessage")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["chat_id"] as? Int, 7)
        XCTAssertEqual(json["text"] as? String, "hello")
        let replyMarkup = try XCTUnwrap(json["reply_markup"] as? [String: Any])
        let inlineKeyboard = try XCTUnwrap(replyMarkup["inline_keyboard"] as? [[[String: Any]]])
        XCTAssertEqual(inlineKeyboard[0][0]["text"] as? String, "Allow Once")
        XCTAssertEqual(inlineKeyboard[0][0]["callback_data"] as? String, "v1|abc|allow_once")
        XCTAssertNil(json["disable_notification"])
    }
}

final class FakeURLSession: URLSessionProtocol, @unchecked Sendable {
    enum Response {
        case success(body: String, status: Int)
    }

    var responses: [String: Response] = [:]
    var recordedRequests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recordedRequests.append(request)
        let path = request.url?.path ?? ""
        let key = responses.keys.first { path.hasSuffix($0) } ?? ""
        guard case .success(let body, let status) = responses[key] else {
            throw URLError(.badServerResponse)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}
