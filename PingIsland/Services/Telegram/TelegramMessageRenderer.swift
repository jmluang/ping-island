import Foundation

enum TelegramAttentionPayload: Equatable {
    case approval(id: String, permission: PermissionContext?, intervention: SessionIntervention?)
    case question(intervention: SessionIntervention)

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
        case .question:
            return TelegramRenderedMessage(text: "", replyMarkup: nil, callbackResolutions: [:])
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

    private struct ApprovalButton {
        let title: String
        let callbackAction: String
        let action: TelegramPersistentState.CallbackResolution.Action
    }
}
