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

    func testInboundWithRegisteredDispatcherForwardsCall() async {
        let hub = InterventionActionHub()
        let spy = SpyDispatcher()
        hub.registerDispatcher(spy)

        let result = await hub.approvePermission(
            sessionId: "s-1",
            forSession: true,
            source: .telegram
        )

        assertSuccess(result)
        XCTAssertEqual(
            spy.calls,
            [.approve(sessionId: "s-1", forSession: true, source: .telegram)]
        )
    }

    func testInboundWithoutDispatcherTimesOutWithDispatcherUnavailable() async {
        let hub = InterventionActionHub(dispatcherWaitTimeout: 0.05)

        let result = await hub.denyPermission(sessionId: "s-1", reason: nil, source: .telegram)

        assertFailure(result, .dispatcherUnavailable)
    }

    func testInboundDispatcherRegisteredWhileWaitingForwardsCall() async {
        let hub = InterventionActionHub(dispatcherWaitTimeout: 1.0)
        let spy = SpyDispatcher()

        async let pending = hub.answerIntervention(
            sessionId: "s-1",
            answers: ["q1": ["yes"]],
            source: .telegram
        )

        try? await Task.sleep(nanoseconds: 20_000_000)
        hub.registerDispatcher(spy)

        let result = await pending
        assertSuccess(result)
        XCTAssertEqual(spy.calls.count, 1)
    }

    private func assertSuccess(
        _ result: Result<Void, InterventionActionDispatchError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            break
        case .failure(let error):
            XCTFail("Expected success, got \(error)", file: file, line: line)
        }
    }

    private func assertFailure(
        _ result: Result<Void, InterventionActionDispatchError>,
        _ expected: InterventionActionDispatchError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("Expected failure \(expected), got success", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }
}

@MainActor
private final class SpyDispatcher: InterventionActionDispatching {
    enum Call: Equatable {
        case approve(sessionId: String, forSession: Bool, source: InterventionResponse.Source)
        case deny(sessionId: String, reason: String?, source: InterventionResponse.Source)
        case answer(
            sessionId: String,
            answers: [String: [String]],
            source: InterventionResponse.Source
        )
    }

    var calls: [Call] = []

    func performApprovePermission(
        sessionId: String,
        forSession: Bool,
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError> {
        calls.append(.approve(sessionId: sessionId, forSession: forSession, source: source))
        return .success(())
    }

    func performDenyPermission(
        sessionId: String,
        reason: String?,
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError> {
        calls.append(.deny(sessionId: sessionId, reason: reason, source: source))
        return .success(())
    }

    func performAnswerIntervention(
        sessionId: String,
        answers: [String: [String]],
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError> {
        calls.append(.answer(sessionId: sessionId, answers: answers, source: source))
        return .success(())
    }
}
