/// The lifecycle status of a loop.
///
/// Part of the queryable ``RegattaLoopState`` snapshot the UI reads.
public enum RegattaLoopStatus: Equatable, Sendable {
    /// The loop has been configured but has not started iterating yet.
    case idle

    /// The loop is actively iterating.
    case running

    /// The loop finished normally or was force-stopped; carries the reason.
    case stopped(RegattaLoopStopReason)

    /// The loop ended because an iteration failed
    /// (``RegattaLoopOutcome/Kind/failed``); carries the failing summary.
    case failed(summary: String)

    /// Whether the loop has reached a terminal status (``stopped`` or
    /// ``failed``) and will run no further iterations.
    public var isTerminal: Bool {
        switch self {
        case .idle, .running:
            return false
        case .stopped, .failed:
            return true
        }
    }
}
