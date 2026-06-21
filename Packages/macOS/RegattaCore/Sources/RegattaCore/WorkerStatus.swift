/// The lifecycle status of a Fleet worker, reflected by a status dot in the UI.
///
/// Transitions follow the real process lifecycle driven by the orchestrator:
/// `.queued` → `.running` → (`.done` | `.failed` | `.cancelled`).
public enum WorkerStatus: Sendable, Equatable {
    /// The worker is accepted but its agent process has not been spawned yet
    /// (e.g. while its worktree is still being provisioned).
    case queued

    /// The agent process is alive and producing output.
    case running

    /// The agent process exited successfully (exit code `0`).
    case done

    /// The agent process exited with a non-zero code, or provisioning failed.
    /// The associated value is a human-readable reason.
    case failed(String)

    /// The worker was cancelled from the Fleet list before completing.
    case cancelled

    /// Whether the worker has reached a terminal state and can no longer change.
    public var isTerminal: Bool {
        switch self {
        case .queued, .running:
            return false
        case .done, .failed, .cancelled:
            return true
        }
    }

    /// Whether the worker can be cancelled in its current state.
    public var isCancellable: Bool {
        switch self {
        case .queued, .running:
            return true
        case .done, .failed, .cancelled:
            return false
        }
    }
}
