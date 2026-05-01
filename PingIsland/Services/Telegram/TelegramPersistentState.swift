import Foundation

struct TelegramPersistentState: Codable, Equatable {
    var version: Int = 1
    var auth: Auth = Auth()
    var poller: Poller = Poller()
    var messages: [String: MessageEntry] = [:]
    var callbacks: [String: CallbackResolution] = [:]

    init(
        version: Int = 1,
        auth: Auth = Auth(),
        poller: Poller = Poller(),
        messages: [String: MessageEntry] = [:],
        callbacks: [String: CallbackResolution] = [:]
    ) {
        self.version = version
        self.auth = auth
        self.poller = poller
        self.messages = messages
        self.callbacks = callbacks
    }

    struct Auth: Codable, Equatable {
        var chatId: Int64?

        init(chatId: Int64? = nil) {
            self.chatId = chatId
        }
    }

    struct Poller: Codable, Equatable {
        var offset: Int64?

        init(offset: Int64? = nil) {
            self.offset = offset
        }
    }

    struct MessageEntry: Codable, Equatable {
        let chatId: Int64
        let messageId: Int64
        let sentAt: Date
    }

    struct CallbackResolution: Codable, Equatable {
        enum Action: Codable, Equatable {
            case allowOnce
            case allowSession
            case deny
            case answerOption(questionId: String, optionTitle: String)
        }

        let sessionId: String
        let interventionId: String
        let action: Action
        let issuedAt: Date
    }
}
