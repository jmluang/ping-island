import Foundation

enum InterventionKey {
    static func make(sessionId: String, interventionId: String) -> String {
        "\(sessionId)|\(interventionId)"
    }

    static func parse(_ key: String) -> (sessionId: String, interventionId: String)? {
        guard let separator = key.firstIndex(of: "|") else {
            return nil
        }

        let sessionId = String(key[..<separator])
        let interventionId = String(key[key.index(after: separator)...])
        guard !sessionId.isEmpty, !interventionId.isEmpty else {
            return nil
        }
        return (sessionId, interventionId)
    }
}
