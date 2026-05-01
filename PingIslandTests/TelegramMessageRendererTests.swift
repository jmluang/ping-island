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

    func testRenderSingleQuestionFixedChoiceUsesOptionButtons() throws {
        let issuedAt = Date(timeIntervalSince1970: 1_775_000_000)
        let intervention = makeQuestionIntervention()
        let session = makeSession(intervention: intervention, phase: .idle)

        let rendered = TelegramMessageRenderer.render(
            session: session,
            payload: .question(intervention: intervention),
            issuedAt: issuedAt,
            tokenProvider: SequentialTokenProvider().nextToken
        )

        XCTAssertEqual(rendered.text, """
        Question requested
        Agent: Claude Code
        Project: ping-island
        Title: Need direction
        Question: Pick a path
        Details: Choose one option
        CWD: /tmp/ping-island
        Session: session-1
        """)
        XCTAssertEqual(rendered.replyMarkup?.inlineKeyboard.flatMap { $0 }.map(\.text), [
            "Option A",
            "Option B"
        ])
        XCTAssertEqual(rendered.replyMarkup?.inlineKeyboard.flatMap { $0 }.map(\.callbackData), [
            "v1|tok1|answer",
            "v1|tok2|answer"
        ])
        XCTAssertEqual(
            rendered.callbackResolutions["tok1"]?.action,
            .answerOption(questionId: "question-1", optionTitle: "Option A")
        )
        XCTAssertEqual(rendered.callbackResolutions["tok1"]?.sessionId, "session-1")
        XCTAssertEqual(rendered.callbackResolutions["tok1"]?.interventionId, "intervention-1")
        XCTAssertEqual(rendered.callbackResolutions["tok1"]?.issuedAt, issuedAt)
    }

    func testRenderAllowsOtherQuestionRoutesBackToMac() {
        let rendered = renderQuestionFallback(makeQuestionIntervention(allowsOther: true))

        XCTAssertEqual(rendered.text, "📝 此问题需要自由文本回答，请在 Mac 上处理")
        XCTAssertNil(rendered.replyMarkup)
        XCTAssertTrue(rendered.callbackResolutions.isEmpty)
    }

    func testRenderSecretQuestionRoutesBackToMac() {
        let rendered = renderQuestionFallback(makeQuestionIntervention(isSecret: true))

        XCTAssertEqual(rendered.text, "🔒 此问题需要密文回答，请在 Mac 上处理")
        XCTAssertNil(rendered.replyMarkup)
        XCTAssertTrue(rendered.callbackResolutions.isEmpty)
    }

    func testRenderMultiSelectQuestionRoutesBackToMac() {
        let rendered = renderQuestionFallback(makeQuestionIntervention(allowsMultiple: true))

        XCTAssertEqual(rendered.text, "☑️ 此问题可多选，请在 Mac 上处理")
        XCTAssertNil(rendered.replyMarkup)
        XCTAssertTrue(rendered.callbackResolutions.isEmpty)
    }

    func testRenderMultiQuestionInterventionRoutesBackToMac() {
        var intervention = makeQuestionIntervention()
        let secondQuestion = SessionInterventionQuestion(
            id: "question-2",
            header: "Second",
            prompt: "Pick again",
            detail: nil,
            options: [
                .init(id: "c", title: "Option C", detail: nil)
            ],
            allowsMultiple: false,
            allowsOther: false,
            isSecret: false
        )
        intervention = SessionIntervention(
            id: intervention.id,
            kind: intervention.kind,
            title: intervention.title,
            message: intervention.message,
            options: intervention.options,
            questions: intervention.questions + [secondQuestion],
            supportsSessionScope: intervention.supportsSessionScope,
            metadata: intervention.metadata
        )

        let rendered = renderQuestionFallback(intervention)

        XCTAssertEqual(rendered.text, "📋 此请求包含多个问题，请在 Mac 上处理")
        XCTAssertNil(rendered.replyMarkup)
        XCTAssertTrue(rendered.callbackResolutions.isEmpty)
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

    private func renderQuestionFallback(_ intervention: SessionIntervention) -> TelegramRenderedMessage {
        TelegramMessageRenderer.render(
            session: makeSession(intervention: intervention, phase: .idle),
            payload: .question(intervention: intervention),
            issuedAt: Date(timeIntervalSince1970: 1_775_000_000),
            tokenProvider: SequentialTokenProvider().nextToken
        )
    }

    private func makeQuestionIntervention(
        allowsMultiple: Bool = false,
        allowsOther: Bool = false,
        isSecret: Bool = false,
        options: [SessionInterventionOption]? = nil
    ) -> SessionIntervention {
        SessionIntervention(
            id: "intervention-1",
            kind: .question,
            title: "Need direction",
            message: "Choose one option",
            options: [],
            questions: [
                SessionInterventionQuestion(
                    id: "question-1",
                    header: "Need direction",
                    prompt: "Pick a path",
                    detail: "Choose one option",
                    options: options ?? [
                        .init(id: "a", title: "Option A", detail: nil),
                        .init(id: "b", title: "Option B", detail: "Second")
                    ],
                    allowsMultiple: allowsMultiple,
                    allowsOther: allowsOther,
                    isSecret: isSecret
                )
            ],
            supportsSessionScope: false,
            metadata: [:]
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
