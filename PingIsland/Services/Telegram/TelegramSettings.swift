import Foundation

struct TelegramSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var masterEnabled: Bool {
        get { boolValue(forKey: Keys.masterEnabled, defaultValue: false) }
        set { defaults.set(newValue, forKey: Keys.masterEnabled) }
    }

    var permissionEvents: Bool {
        get { boolValue(forKey: Keys.permissionEvents, defaultValue: true) }
        set { defaults.set(newValue, forKey: Keys.permissionEvents) }
    }

    var questionEvents: Bool {
        get { boolValue(forKey: Keys.questionEvents, defaultValue: true) }
        set { defaults.set(newValue, forKey: Keys.questionEvents) }
    }

    var completionEvents: Bool {
        get { boolValue(forKey: Keys.completionEvents, defaultValue: false) }
        set { defaults.set(newValue, forKey: Keys.completionEvents) }
    }

    var errorEvents: Bool {
        get { boolValue(forKey: Keys.errorEvents, defaultValue: false) }
        set { defaults.set(newValue, forKey: Keys.errorEvents) }
    }

    var limitEvents: Bool {
        get { boolValue(forKey: Keys.limitEvents, defaultValue: false) }
        set { defaults.set(newValue, forKey: Keys.limitEvents) }
    }

    func isEnabled(for event: TelegramEventCategory) -> Bool {
        guard masterEnabled else { return false }

        switch event {
        case .permission:
            return permissionEvents
        case .question:
            return questionEvents
        case .completion:
            return completionEvents
        case .error:
            return errorEvents
        case .limit:
            return limitEvents
        }
    }

    private func boolValue(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }

        return defaults.bool(forKey: key)
    }

    enum Keys {
        static let masterEnabled = "Telegram.master"
        static let permissionEvents = "Telegram.events.permission"
        static let questionEvents = "Telegram.events.question"
        static let completionEvents = "Telegram.events.completion"
        static let errorEvents = "Telegram.events.error"
        static let limitEvents = "Telegram.events.limit"
    }
}

enum TelegramEventCategory {
    case permission
    case question
    case completion
    case error
    case limit
}
