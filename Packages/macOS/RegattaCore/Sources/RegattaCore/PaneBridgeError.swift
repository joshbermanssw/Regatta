public import Foundation

/// Errors thrown by a ``PaneBridge``.
public enum PaneBridgeError: Error, Equatable, CustomStringConvertible {
    /// The process could not be launched (e.g. the executable does not exist or is not runnable).
    ///
    /// The associated string is the underlying failure description.
    case spawnFailed(String)

    /// No pane is tracked for the given handle id (it was never spawned, or already finished).
    case unknownHandle(PaneHandle.ID)

    public var description: String {
        switch self {
        case .spawnFailed(let detail):
            return "Failed to spawn agent process: \(detail)"
        case .unknownHandle(let id):
            return "No active pane for handle \(id)."
        }
    }
}
