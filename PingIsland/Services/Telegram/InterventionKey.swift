import Foundation

enum InterventionKey {
    static func make(sessionId: String, interventionId: String) -> String {
        "\(sessionId)|\(interventionId)"
    }
}
