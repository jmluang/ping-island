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
enum InterventionActionDispatchError: Error, Equatable {
    case dispatcherUnavailable
    case actionNotHandled
}

@MainActor
protocol InterventionActionDispatching: AnyObject {
    func performApprovePermission(
        sessionId: String,
        forSession: Bool,
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError>

    func performDenyPermission(
        sessionId: String,
        reason: String?,
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError>

    func performAnswerIntervention(
        sessionId: String,
        answers: [String: [String]],
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError>
}

@MainActor
final class InterventionActionHub {
    static let shared = InterventionActionHub()

    let responded = PassthroughSubject<InterventionResponse, Never>()

    private weak var dispatcher: (any InterventionActionDispatching)?
    private let dispatcherWaitTimeout: TimeInterval
    private var dispatcherWaiters: [UUID: CheckedContinuation<(any InterventionActionDispatching)?, Never>] = [:]

    init(dispatcherWaitTimeout: TimeInterval = 5.0) {
        self.dispatcherWaitTimeout = dispatcherWaitTimeout
    }

    func publish(_ response: InterventionResponse) {
        responded.send(response)
    }

    func registerDispatcher(_ dispatcher: any InterventionActionDispatching) {
        self.dispatcher = dispatcher
        let waiters = dispatcherWaiters.values
        dispatcherWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: dispatcher)
        }
    }

    private func awaitDispatcher() async -> (any InterventionActionDispatching)? {
        if let dispatcher {
            return dispatcher
        }

        let timeoutNanos = UInt64(max(0, dispatcherWaitTimeout) * 1_000_000_000)
        let waiterID = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                dispatcherWaiters[waiterID] = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanos)
                    guard let self,
                          let continuation = self.dispatcherWaiters.removeValue(forKey: waiterID)
                    else {
                        return
                    }
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let continuation = self?.dispatcherWaiters.removeValue(forKey: waiterID) else {
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    func approvePermission(
        sessionId: String,
        forSession: Bool,
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError> {
        guard let dispatcher = await awaitDispatcher() else {
            return .failure(.dispatcherUnavailable)
        }
        return await dispatcher.performApprovePermission(
            sessionId: sessionId,
            forSession: forSession,
            source: source
        )
    }

    func denyPermission(
        sessionId: String,
        reason: String?,
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError> {
        guard let dispatcher = await awaitDispatcher() else {
            return .failure(.dispatcherUnavailable)
        }
        return await dispatcher.performDenyPermission(
            sessionId: sessionId,
            reason: reason,
            source: source
        )
    }

    func answerIntervention(
        sessionId: String,
        answers: [String: [String]],
        source: InterventionResponse.Source
    ) async -> Result<Void, InterventionActionDispatchError> {
        guard let dispatcher = await awaitDispatcher() else {
            return .failure(.dispatcherUnavailable)
        }
        return await dispatcher.performAnswerIntervention(
            sessionId: sessionId,
            answers: answers,
            source: source
        )
    }
}
