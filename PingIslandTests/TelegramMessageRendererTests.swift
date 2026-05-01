import XCTest
@testable import Ping_Island

final class TelegramMessageRendererTests: XCTestCase {
    func testRenderApprovalNonCodexUsesTwoButtons() throws {
        let issuedAt = Date(timeIntervalSince1970: 1_775_000_000)
        let session = makeSession(
            provider: .claude,
            phase: .waitingForApproval(makePermission())
        )
        let payload = try XCTUnwrap(TelegramAttentionPayload.approval(for: session))

        let rendered = TelegramMessageRenderer.render(
            session: session,
            payload: payload,
            issuedAt: issuedAt,
            tokenProvider: SequentialTokenProvider().nextToken
        )

        XCTAssertEqual(rendered.text, """
        Approval requested
        Agent: Claude Code
        Project: ping-island
        Tool: Bash
        CWD: /tmp/ping-island
        Session: session-1

        Input:
        command: npm test
        """)
        XCTAssertEqual(rendered.replyMarkup?.inlineKeyboard.flatMap { $0 }.map(\.text), [
            "Allow Once",
            "Deny"
        ])
        XCTAssertEqual(rendered.replyMarkup?.inlineKeyboard.flatMap { $0 }.map(\.callbackData), [
            "v1|tok1|allow_once",
            "v1|tok2|deny"
        ])
        XCTAssertEqual(rendered.callbackResolutions["tok1"]?.action, .allowOnce)
        XCTAssertEqual(rendered.callbackResolutions["tok2"]?.action, .deny)
        XCTAssertEqual(rendered.callbackResolutions["tok1"]?.sessionId, "session-1")
        XCTAssertEqual(rendered.callbackResolutions["tok1"]?.interventionId, "tool-1")
        XCTAssertEqual(rendered.callbackResolutions["tok1"]?.issuedAt, issuedAt)
    }

    func testRenderApprovalCodexUsesAllowSessionButton() throws {
        let session = makeSession(
            provider: .codex,
            ingress: .codexAppServer,
            phase: .waitingForApproval(makePermission(toolUseId: "codex-tool-1", toolName: "Edit"))
        )
        let payload = try XCTUnwrap(TelegramAttentionPayload.approval(for: session))

        let rendered = TelegramMessageRenderer.render(
            session: session,
            payload: payload,
            issuedAt: Date(timeIntervalSince1970: 1_775_000_000),
            tokenProvider: SequentialTokenProvider().nextToken
        )

        XCTAssertEqual(rendered.replyMarkup?.inlineKeyboard.flatMap { $0 }.map(\.text), [
            "Allow Once",
            "Deny",
            "Allow Session"
        ])
        XCTAssertEqual(rendered.replyMarkup?.inlineKeyboard.flatMap { $0 }.map(\.callbackData), [
            "v1|tok1|allow_once",
            "v1|tok2|deny",
            "v1|tok3|allow_session"
        ])
        XCTAssertEqual(rendered.callbackResolutions["tok3"]?.action, .allowSession)
    }

    func testRenderApprovalTruncatesAtTelegramLimit() throws {
        let intervention = SessionIntervention(
            id: "intervention-1",
            kind: .approval,
            title: "Bash",
            message: String(repeating: "a", count: 4_200),
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [:]
        )
        let session = makeSession(
            intervention: intervention,
            phase: .idle
        )
        let payload = try XCTUnwrap(TelegramAttentionPayload.approval(for: session))

        let rendered = TelegramMessageRenderer.render(
            session: session,
            payload: payload,
            issuedAt: Date(timeIntervalSince1970: 1_775_000_000),
            tokenProvider: SequentialTokenProvider().nextToken
        )

        XCTAssertEqual(rendered.text.count, 4096)
        XCTAssertTrue(rendered.text.hasSuffix("… (truncated; open notch for full)"))
    }

    private func makeSession(
        provider: SessionProvider = .claude,
        ingress: SessionIngress = .hookBridge,
        intervention: SessionIntervention? = nil,
        phase: SessionPhase
    ) -> SessionState {
        SessionState(
            sessionId: "session-1",
            cwd: "/tmp/ping-island",
            projectName: "ping-island",
            provider: provider,
            ingress: ingress,
            intervention: intervention,
            phase: phase
        )
    }

    private func makePermission(
        toolUseId: String = "tool-1",
        toolName: String = "Bash",
        input: [String: AnyCodable] = ["command": AnyCodable("npm test")]
    ) -> PermissionContext {
        PermissionContext(
            toolUseId: toolUseId,
            toolName: toolName,
            toolInput: input,
            receivedAt: Date(timeIntervalSince1970: 1_775_000_000)
        )
    }
}

private final class SequentialTokenProvider {
    private var index = 0

    func nextToken(_ action: TelegramPersistentState.CallbackResolution.Action) -> String {
        index += 1
        return "tok\(index)"
    }
}
