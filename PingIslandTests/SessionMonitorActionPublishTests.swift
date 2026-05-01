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

    func testApprovePermissionPublishesApproveOnceWithSource() async {
        let hub = InterventionActionHub()
        var received: [InterventionResponse] = []
        let cancellable = hub.responded.sink { received.append($0) }
        defer { cancellable.cancel() }

        let monitor = SessionMonitor(observeSharedState: false, actionHub: hub)
        await SessionStore.shared.process(.hookReceived(makePermissionRequest(
            sessionId: "action-publish-approve",
            toolUseId: "tool-approve"
        )))

        let result = await monitor.performApprovePermission(
            sessionId: "action-publish-approve",
            forSession: false,
            source: .telegram
        )

        assertSuccess(result)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.sessionId, "action-publish-approve")
        XCTAssertEqual(received.first?.interventionId, "tool-approve")
        XCTAssertEqual(received.first?.source, .telegram)
        XCTAssertEqual(received.first?.decision, .approveOnce)

        await SessionStore.shared.process(.sessionArchived(sessionId: "action-publish-approve"))
    }

    func testDenyPermissionPublishesDenyWithSource() async {
        let hub = InterventionActionHub()
        var received: [InterventionResponse] = []
        let cancellable = hub.responded.sink { received.append($0) }
        defer { cancellable.cancel() }

        let monitor = SessionMonitor(observeSharedState: false, actionHub: hub)
        await SessionStore.shared.process(.hookReceived(makePermissionRequest(
            sessionId: "action-publish-deny",
            toolUseId: "tool-deny"
        )))

        let result = await monitor.performDenyPermission(
            sessionId: "action-publish-deny",
            reason: nil,
            source: .telegram
        )

        assertSuccess(result)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.sessionId, "action-publish-deny")
        XCTAssertEqual(received.first?.interventionId, "tool-deny")
        XCTAssertEqual(received.first?.source, .telegram)
        XCTAssertEqual(received.first?.decision, .deny(reason: nil))

        await SessionStore.shared.process(.sessionArchived(sessionId: "action-publish-deny"))
    }

    func testAnswerInterventionPublishesAnswerWithSource() async {
        let hub = InterventionActionHub()
        var received: [InterventionResponse] = []
        let cancellable = hub.responded.sink { received.append($0) }
        defer { cancellable.cancel() }

        let monitor = SessionMonitor(observeSharedState: false, actionHub: hub)
        await SessionStore.shared.process(.hookReceived(makeQuestionRequest(
            sessionId: "action-publish-answer",
            toolUseId: "tool-answer"
        )))

        let answers = ["mode": ["auto"]]
        let result = await monitor.performAnswerIntervention(
            sessionId: "action-publish-answer",
            answers: answers,
            source: .telegram
        )

        assertSuccess(result)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.sessionId, "action-publish-answer")
        XCTAssertEqual(received.first?.interventionId, "tool-answer")
        XCTAssertEqual(received.first?.source, .telegram)
        XCTAssertEqual(received.first?.decision, .answer(answers: answers))

        await SessionStore.shared.process(.sessionArchived(sessionId: "action-publish-answer"))
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

    private func makePermissionRequest(sessionId: String, toolUseId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode"
            ),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: ["command": AnyCodable("swift test")],
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }

    private func makeQuestionRequest(sessionId: String, toolUseId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "mode",
                        "header": "Mode",
                        "question": "Pick a mode",
                        "options": [["label": "auto"], ["label": "manual"]]
                    ]
                ])
            ],
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }
}
