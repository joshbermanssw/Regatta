public import RegattaCore

/// The loop view's lifecycle phase, projected from the engine's
/// ``RegattaLoopStatus`` plus the view model's own control intents.
///
/// The engine status only knows `idle` / `running` / `stopped` / `failed`. The
/// loop view layers two interaction phases on top that the engine has no concept
/// of:
/// - ``paused`` — the user asked the in-flight run to stop at the next iteration
///   boundary so they can inspect or take over; the configuration is preserved
///   and a fresh engine can resume it.
/// - ``editing`` — the user is changing the goal / condition / caps; controls
///   that would start the loop are gated until they commit.
///
/// This is a value type so it can be read directly by SwiftUI and compared for
/// equality without reaching into the engine actor.
public enum RegattaLoopRunPhase: Equatable, Sendable {
    /// Configured but never started, or fully reset.
    case idle

    /// Actively iterating.
    case running

    /// Stopped after the current iteration at the user's request; resumable.
    case paused

    /// The user is editing the goal / condition / caps.
    case editing

    /// Finished — carries the underlying terminal status for reason display.
    case finished(RegattaLoopStatus)

    /// Whether a new iteration could currently be started or resumed.
    public var canStart: Bool {
        switch self {
        case .idle, .paused:
            return true
        case .running, .editing, .finished:
            return false
        }
    }

    /// Whether the loop is in flight and can be paused or stopped.
    public var isActive: Bool {
        if case .running = self { return true }
        return false
    }
}
