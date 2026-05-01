import Combine
import XCTest
@testable import Ping_Island

@MainActor
final class InterventionActionHubTests: XCTestCase {
    func testPublishEmitsResponseToSubscribers() {
        let hub = InterventionActionHub()
        var received: [InterventionResponse] = []
        let cancellable = hub.responded.sink { received.append($0) }
        defer { cancellable.cancel() }

        let response = InterventionResponse(
            sessionId: "s-1",
            interventionId: "i-1",
            decision: .approveOnce,
            source: .mac,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        hub.publish(response)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.sessionId, "s-1")
        XCTAssertEqual(received.first?.source, .mac)
    }
}
