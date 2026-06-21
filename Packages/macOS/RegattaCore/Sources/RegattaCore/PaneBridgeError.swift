/// Errors thrown by a ``PaneBridge``.
public enum PaneBridgeError: Error, Equatable, CustomStringConvertible {
    /// No live process is tracked for the given handle ID (already finished,
    /// terminated, or never spawned).
    case unknownHandle(PaneHandle.ID)

    /// The process failed to launch (e.g. the executable could not be run).
    case spawnFailed(String)

    public var description: String {
        switch self {
        case .unknownHandle(let id):
            return "No running pane process for handle \(id)."
        case .spawnFailed(let detail):
            return "Failed to spawn pane process: \(detail)"
        }
    }
}
