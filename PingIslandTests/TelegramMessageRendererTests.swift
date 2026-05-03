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

        XCTAssertEqual(rendered.text, [
            TelegramL10n.format("Telegram.Message.ApprovalRequestedBy", "Claude Code"),
            TelegramL10n.format("Telegram.Message.Field.Agent", "Claude Code"),
            TelegramL10n.format("Telegram.Message.Field.Project", "ping-island"),
            TelegramL10n.format("Telegram.Message.Field.Tool", "Bash"),
            TelegramL10n.format("Telegram.Message.Field.CWD", "/tmp/ping-island"),
            TelegramL10n.format("Telegram.Message.Field.Session", "session-1"),
            "",
            TelegramL10n.string("Telegram.Message.Field.Input"),
            "command: npm test"
        ].joined(separator: "\n"))
        XCTAssertEqual(rendered.replyMarkup?.inlineKeyboard.flatMap { $0 }.map(\.text), [
            TelegramL10n.string("Telegram.Button.AllowOnce"),
            TelegramL10n.string("Telegram.Button.Deny")
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
            TelegramL10n.string("Telegram.Button.AllowOnce"),
            TelegramL10n.string("Telegram.Button.Deny"),
            TelegramL10n.string("Telegram.Button.AllowSession")
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
        XCTAssertTrue(rendered.text.hasSuffix(TelegramL10n.string("Telegram.Message.TruncatedSuffix")))
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

        XCTAssertEqual(rendered.text, [
            TelegramL10n.string("Telegram.Message.QuestionRequested"),
            TelegramL10n.format("Telegram.Message.Field.Agent", "Claude Code"),
            TelegramL10n.format("Telegram.Message.Field.Project", "ping-island"),
            TelegramL10n.format("Telegram.Message.Field.Title", "Need direction"),
            TelegramL10n.format("Telegram.Message.Field.Question", "Pick a path"),
            TelegramL10n.format("Telegram.Message.Field.Details", "Choose one option"),
            TelegramL10n.format("Telegram.Message.Field.CWD", "/tmp/ping-island"),
            TelegramL10n.format("Telegram.Message.Field.Session", "session-1")
        ].joined(separator: "\n"))
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

        XCTAssertEqual(rendered.text, [
            TelegramL10n.string("Telegram.Message.QuestionFallback.FreeText"),
            TelegramL10n.format("Telegram.Message.Field.Agent", "Claude Code"),
            TelegramL10n.format("Telegram.Message.Field.Project", "ping-island"),
            TelegramL10n.format("Telegram.Message.Field.Title", "Need direction"),
            TelegramL10n.format("Telegram.Message.Field.Question", "Pick a path"),
            TelegramL10n.format("Telegram.Message.Field.Details", "Choose one option"),
            TelegramL10n.format("Telegram.Message.Field.CWD", "/tmp/ping-island"),
            TelegramL10n.format("Telegram.Message.Field.Session", "session-1")
        ].joined(separator: "\n"))
        XCTAssertNil(rendered.replyMarkup)
        XCTAssertTrue(rendered.callbackResolutions.isEmpty)
    }

    func testRenderSecretQuestionRoutesBackToMac() {
        let rendered = renderQuestionFallback(makeQuestionIntervention(isSecret: true))

        XCTAssertTrue(rendered.text.hasPrefix(TelegramL10n.string("Telegram.Message.QuestionFallback.Secret")))
        XCTAssertTrue(rendered.text.contains(TelegramL10n.format("Telegram.Message.Field.Question", "Pick a path")))
        XCTAssertNil(rendered.replyMarkup)
        XCTAssertTrue(rendered.callbackResolutions.isEmpty)
    }

    func testRenderMultiSelectQuestionRoutesBackToMac() {
        let rendered = renderQuestionFallback(makeQuestionIntervention(allowsMultiple: true))

        XCTAssertTrue(rendered.text.hasPrefix(TelegramL10n.string("Telegram.Message.QuestionFallback.MultipleChoice")))
        XCTAssertTrue(rendered.text.contains(TelegramL10n.format("Telegram.Message.Field.Question", "Pick a path")))
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

        XCTAssertTrue(rendered.text.hasPrefix(TelegramL10n.string("Telegram.Message.QuestionFallback.MultipleQuestions")))
        XCTAssertTrue(rendered.text.contains(TelegramL10n.format("Telegram.Message.Field.Question", "Pick a path")))
        XCTAssertTrue(rendered.text.contains(TelegramL10n.format("Telegram.Message.Field.Question", "Pick again")))
        XCTAssertNil(rendered.replyMarkup)
        XCTAssertTrue(rendered.callbackResolutions.isEmpty)
    }

    func testSimplifiedChineseTelegramApprovalCopiesMacApprovalLanguage() throws {
        let zhHans = try localizationFileContents(named: "zh-Hans")

        XCTAssertTrue(zhHans.contains("\"Telegram.Button.AllowOnce\" = \"允许一次\";"))
        XCTAssertTrue(zhHans.contains("\"Telegram.Button.Deny\" = \"拒绝\";"))
        XCTAssertTrue(zhHans.contains("\"Telegram.Button.AllowSession\" = \"允许本次会话\";"))
        XCTAssertTrue(zhHans.contains("\"Telegram.Message.Decision.ApprovedOnce\" = \"已允许一次\";"))
        XCTAssertTrue(zhHans.contains("\"Telegram.Message.Decision.ApprovedForSession\" = \"已允许本次会话\";"))
        XCTAssertTrue(zhHans.contains("\"Telegram.Message.Decision.Denied\" = \"已拒绝\";"))
        XCTAssertTrue(zhHans.contains("\"Telegram.Message.ApprovalRequestedBy\" = \"%@ 请求批准\";"))
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

    private func localizationFileContents(named localeCode: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDirectory.deletingLastPathComponent()
        let fileURL = repoRoot
            .appendingPathComponent("PingIsland")
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(localeCode).lproj")
            .appendingPathComponent("Localizable.strings")
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}

private final class SequentialTokenProvider {
    private var index = 0

    func nextToken(_ action: TelegramPersistentState.CallbackResolution.Action) -> String {
        index += 1
        return "tok\(index)"
    }
}
