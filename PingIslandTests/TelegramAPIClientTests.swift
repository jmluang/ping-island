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
