enum TelegramText {
    static let truncationSuffix = "… (truncated; open notch for full)"

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
