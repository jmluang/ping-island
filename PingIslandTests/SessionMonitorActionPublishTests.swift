import Combine
import XCTest
@testable import Ping_Island

@MainActor
final class SessionMonitorActionPublishTests: XCTestCase {
    func testMonitorCanBeConstructedForSignatureChecks() {
        let monitor = SessionMonitor()
        XCTAssertNotNil(monitor)
    }

    func testMethodSignaturesAcceptSourceParameter() {
        let monitor = SessionMonitor()
        monitor.approvePermission(sessionId: "s-1", forSession: false, source: .mac)
        monitor.denyPermission(sessionId: "s-1", reason: nil, source: .mac)
        monitor.answerIntervention(sessionId: "s-1", answers: [:], source: .mac)
    }
}
