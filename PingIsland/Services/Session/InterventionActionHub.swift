import Combine
import Foundation

struct InterventionResponse: Equatable {
    enum Source: String, Equatable {
        case mac
        case telegram
    }

    enum Decision: Equatable {
        case approveOnce
        case approveForSession
        case deny(reason: String?)
        case answer(answers: [String: [String]])
    }

    let sessionId: String
    let interventionId: String
    let decision: Decision
    let source: Source
    let timestamp: Date
}

@MainActor
final class InterventionActionHub {
    static let shared = InterventionActionHub()

    let responded = PassthroughSubject<InterventionResponse, Never>()

    func publish(_ response: InterventionResponse) {
        responded.send(response)
    }
}
