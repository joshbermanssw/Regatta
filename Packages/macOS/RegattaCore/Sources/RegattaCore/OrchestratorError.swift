public import Foundation

/// Errors thrown by ``RegattaOrchestrator``.
public enum OrchestratorError: Error, Equatable, CustomStringConvertible {
    /// No worker is tracked for the given ID.
    case unknownWorker(UUID)

    public var description: String {
        switch self {
        case .unknownWorker(let id):
            return "No worker is tracked with id \(id.uuidString)."
        }
    }
}
