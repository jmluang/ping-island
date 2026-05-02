import Foundation

enum TelegramAttentionPayload: Equatable {
    case approval(id: String, permission: PermissionContext?, intervention: SessionIntervention?)
    case question(intervention: SessionIntervention)
    case completion
    case error(toolId: String)

    var category: TelegramEventCategory {
        switch self {
        case .approval:
            return .permission
        case .question:
            return .question
        case .completion:
            return .completion
        case .error:
            return .error
        }
    }

    static func approval(for session: SessionState) -> TelegramAttentionPayload? {
        if let permission = session.activePermission {
            return .approval(
                id: permission.toolUseId,
                permission: permission,
                intervention: session.intervention
            )
        }

        guard let intervention = session.intervention, intervention.kind == .approval else {
            return nil
        }

        return .approval(id: intervention.id, permission: nil, intervention: intervention)
    }

    static func renderable(for session: SessionState) -> (id: String, payload: TelegramAttentionPayload)? {
        if let approval = approval(for: session),
           case .approval(let id, _, _) = approval {
            return (id, approval)
        }

        guard let intervention = session.intervention, intervention.kind == .question else {
            return nil
        }

        return (intervention.id, .question(intervention: intervention))
    }

    static func isFixedChoiceQuestion(_ intervention: SessionIntervention) -> Bool {
        let questions = intervention.resolvedQuestions
        guard questions.count == 1, let question = questions.first else {
            return false
        }

        return !question.allowsOther
            && !question.isSecret
            && !question.allowsMultiple
            && !question.options.isEmpty
    }
}

struct TelegramRenderedMessage: Equatable {
    let text: String
    let replyMarkup: TelegramInlineKeyboardMarkup?
    let callbackResolutions: [String: TelegramPersistentState.CallbackResolution]
}

enum TelegramMessageRenderer {
    typealias TokenProvider = (TelegramPersistentState.CallbackResolution.Action) -> String

    static func render(
        session: SessionState,
        payload: TelegramAttentionPayload,
        issuedAt: Date = Date(),
        tokenProvider: TokenProvider
    ) -> TelegramRenderedMessage {
        switch payload {
        case .approval(let id, let permission, let intervention):
            return renderApproval(
                session: session,
                interventionId: id,
                permission: permission,
                intervention: intervention,
                issuedAt: issuedAt,
                tokenProvider: tokenProvider
            )
        case .question(let intervention):
            return renderQuestion(
                session: session,
                intervention: intervention,
                issuedAt: issuedAt,
                tokenProvider: tokenProvider
            )
        case .completion:
            return renderStatus(text: completionText(for: session))
        case .error(let toolId):
            return renderStatus(text: errorText(for: session, toolId: toolId))
        }
    }

    private static func renderApproval(
        session: SessionState,
        interventionId: String,
        permission: PermissionContext?,
        intervention: SessionIntervention?,
        issuedAt: Date,
        tokenProvider: TokenProvider
    ) -> TelegramRenderedMessage {
        let rawText = approvalText(
            session: session,
            permission: permission,
            intervention: intervention
        )
        let actions = approvalActions(for: session)
        var resolutions: [String: TelegramPersistentState.CallbackResolution] = [:]
        let buttons = actions.map { button in
            let token = tokenProvider(button.action)
            resolutions[token] = TelegramPersistentState.CallbackResolution(
                sessionId: session.sessionId,
                interventionId: interventionId,
                action: button.action,
                issuedAt: issuedAt
            )
            return TelegramInlineKeyboardButton(
                text: button.title,
                callbackData: "v1|\(token)|\(button.callbackAction)"
            )
        }

        return TelegramRenderedMessage(
            text: TelegramText.truncate(rawText, limit: 4096),
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [buttons]),
            callbackResolutions: resolutions
        )
    }

    private static func approvalText(
        session: SessionState,
        permission: PermissionContext?,
        intervention: SessionIntervention?
    ) -> String {
        let toolName = permission?.toolName
            ?? session.pendingToolName
            ?? intervention?.title
            ?? "Permission"
        let input = permission?.formattedInput
            ?? session.pendingToolInput
            ?? intervention?.message

        var lines = [
            "Approval requested",
            "Agent: \(session.messageBadgeDisplayName)",
            "Project: \(session.projectName)",
            "Tool: \(toolName)",
            "CWD: \(session.cwd)",
            "Session: \(session.sessionId)"
        ]

        if let input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("Input:")
            lines.append(input)
        }

        return lines.joined(separator: "\n")
    }

    private static func approvalActions(for session: SessionState) -> [ApprovalButton] {
        var buttons = [
            ApprovalButton(title: "Allow Once", callbackAction: "allow_once", action: .allowOnce),
            ApprovalButton(title: "Deny", callbackAction: "deny", action: .deny)
        ]

        if session.provider == .codex, session.scopedApprovalAction != nil {
            buttons.append(ApprovalButton(
                title: "Allow Session",
                callbackAction: "allow_session",
                action: .allowSession
            ))
        }

        return buttons
    }

    private static func renderQuestion(
        session: SessionState,
        intervention: SessionIntervention,
        issuedAt: Date,
        tokenProvider: TokenProvider
    ) -> TelegramRenderedMessage {
        let questions = intervention.resolvedQuestions
        guard TelegramAttentionPayload.isFixedChoiceQuestion(intervention),
              let question = questions.first
        else {
            return TelegramRenderedMessage(
                text: TelegramText.truncate(questionFallbackText(for: intervention), limit: 4096),
                replyMarkup: nil,
                callbackResolutions: [:]
            )
        }

        var resolutions: [String: TelegramPersistentState.CallbackResolution] = [:]
        let buttons = question.options.map { option in
            let action = TelegramPersistentState.CallbackResolution.Action.answerOption(
                questionId: question.id,
                optionTitle: option.title
            )
            let token = tokenProvider(action)
            resolutions[token] = TelegramPersistentState.CallbackResolution(
                sessionId: session.sessionId,
                interventionId: intervention.id,
                action: action,
                issuedAt: issuedAt
            )
            return TelegramInlineKeyboardButton(
                text: option.title,
                callbackData: "v1|\(token)|answer"
            )
        }

        return TelegramRenderedMessage(
            text: TelegramText.truncate(questionText(session: session, intervention: intervention, question: question), limit: 4096),
            replyMarkup: TelegramInlineKeyboardMarkup(inlineKeyboard: [buttons]),
            callbackResolutions: resolutions
        )
    }

    private static func questionText(
        session: SessionState,
        intervention: SessionIntervention,
        question: SessionInterventionQuestion
    ) -> String {
        var lines = [
            "Question requested",
            "Agent: \(session.messageBadgeDisplayName)",
            "Project: \(session.projectName)",
            "Title: \(intervention.title)",
            "Question: \(question.prompt)"
        ]

        if let detail = question.detail ?? (!intervention.message.isEmpty ? intervention.message : nil),
           !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Details: \(detail)")
        }

        lines.append("CWD: \(session.cwd)")
        lines.append("Session: \(session.sessionId)")
        return lines.joined(separator: "\n")
    }

    private static func questionFallbackText(for intervention: SessionIntervention) -> String {
        let questions = intervention.resolvedQuestions
        guard questions.count == 1, let question = questions.first else {
            return "📋 此请求包含多个问题，请在 Mac 上处理"
        }

        if question.isSecret {
            return "🔒 此问题需要密文回答，请在 Mac 上处理"
        }

        if question.allowsMultiple {
            return "☑️ 此问题可多选，请在 Mac 上处理"
        }

        return "📝 此问题需要自由文本回答，请在 Mac 上处理"
    }

    private static func renderStatus(text: String) -> TelegramRenderedMessage {
        TelegramRenderedMessage(
            text: TelegramText.truncate(text, limit: 4096),
            replyMarkup: nil,
            callbackResolutions: [:]
        )
    }

    private static func completionText(for session: SessionState) -> String {
        var lines = [
            "Task completed",
            "Agent: \(session.messageBadgeDisplayName)",
            "Project: \(session.projectName)",
            "CWD: \(session.cwd)",
            "Session: \(session.sessionId)"
        ]

        if let preview = latestAssistantPreview(for: session) {
            lines.append("")
            lines.append("Result:")
            lines.append(preview)
        }

        return lines.joined(separator: "\n")
    }

    private static func errorText(for session: SessionState, toolId: String) -> String {
        [
            "Task error",
            "Agent: \(session.messageBadgeDisplayName)",
            "Project: \(session.projectName)",
            "Tool ID: \(toolId)",
            "CWD: \(session.cwd)",
            "Session: \(session.sessionId)"
        ].joined(separator: "\n")
    }

    private static func latestAssistantPreview(for session: SessionState) -> String? {
        for item in session.chatItems.reversed() {
            if case .assistant(let text) = item.type {
                return sanitizedPreview(text)
            }
        }

        guard session.lastMessageRole == "assistant" else {
            return nil
        }

        return sanitizedPreview(session.lastMessage)
    }

    private static func sanitizedPreview(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private struct ApprovalButton {
        let title: String
        let callbackAction: String
        let action: TelegramPersistentState.CallbackResolution.Action
    }
}
