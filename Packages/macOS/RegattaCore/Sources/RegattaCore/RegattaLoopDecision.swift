public import Foundation

/// What a ``RegattaLoopCondition`` decides after observing a completed
/// iteration: keep going, stop normally, or stop because the iteration failed.
///
/// This is the loop state machine's transition vocabulary. The engine layers
/// the hard safety caps on top of whatever a condition decides — a condition can
/// never override a cap.
public enum RegattaLoopDecision: Equatable, Sendable {
    /// Run another iteration.
    case `continue`

    /// Stop the loop normally, with the given reason.
    case stop(RegattaLoopStopReason)

    /// Stop the loop because an iteration failed, carrying its summary.
    case fail(summary: String)
}
