import Foundation

enum TelegramText {
    static var truncationSuffix: String {
        TelegramL10n.string("Telegram.Message.TruncatedSuffix")
    }

    static func truncate(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        guard limit > truncationSuffix.count else {
            let endIndex = truncationSuffix.index(truncationSuffix.startIndex, offsetBy: limit)
            return String(truncationSuffix[..<endIndex])
        }

        let prefixLength = limit - truncationSuffix.count
        let endIndex = text.index(text.startIndex, offsetBy: prefixLength)
        return String(text[..<endIndex]) + truncationSuffix
    }
}

enum TelegramL10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}
