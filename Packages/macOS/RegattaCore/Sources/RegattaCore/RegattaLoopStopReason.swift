public import Foundation

/// Why a loop is no longer running.
///
/// Distinguishes a normal completion (goal reached / iteration count met /
/// user-requested) from a hard cap force-stop, so the UI can show "stopped by
/// cap" prominently. Used by ``RegattaLoopStatus``.
public enum RegattaLoopStopReason: Equatable, Sendable {
    /// The worker reported the goal was reached
    /// (``RegattaLoopOutcome/Kind/succeeded``).
    case goalReached

    /// The configured `N iterations` count was met
    /// (``RegattaLoopStopCondition/iterations(_:)``).
    case iterationCountMet

    /// A caller requested a manual stop (see
    /// ``RegattaLoopEngine/requestManualStop()``).
    case manualStop

    /// The hard ``RegattaLoopSafetyCaps/maxIterations`` cap was hit.
    case maxIterationsCap

    /// The hard ``RegattaLoopSafetyCaps/tokenBudget`` cap was hit.
    case tokenBudgetCap

    /// Whether this reason represents a hard safety-cap force-stop rather than a
    /// normal exit. The UI marks cap-stopped loops distinctly.
    public var isSafetyCap: Bool {
        switch self {
        case .maxIterationsCap, .tokenBudgetCap:
            return true
        case .goalReached, .iterationCountMet, .manualStop:
            return false
        }
    }
}
