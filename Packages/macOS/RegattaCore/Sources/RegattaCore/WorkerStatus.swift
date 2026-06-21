/// The lifecycle status of a Fleet worker, reflected by a status dot in the UI.
///
/// Transitions follow the real process lifecycle driven by the orchestrator:
/// `.queued` → `.running` → (`.done` | `.failed` | `.cancelled`).
///
/// ``interrupted`` is the restore state: when Regatta relaunches after a quit or
/// crash, a worker that was mid-flight cannot have its live agent process
/// resumed (issue #34). It is restored as ``interrupted`` — a non-terminal,
/// relaunchable state that signals "this worker had work in progress that was
/// cut off" so the Fleet UI can offer to relaunch it.
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

    /// The worker's live agent process was lost across an app restart and could
    /// not be resumed. It is non-terminal and can be relaunched. See issue #34
    /// (state persistence + session restore).
    case interrupted

    /// Whether the worker has reached a terminal state and can no longer change.
    ///
    /// ``interrupted`` is **not** terminal: it represents work that was cut off
    /// by a restart and is awaiting relaunch.
    public var isTerminal: Bool {
        switch self {
        case .queued, .running, .interrupted:
            return false
        case .done, .failed, .cancelled:
            return true
        }
    }

    /// Whether the worker can be cancelled in its current state.
    public var isCancellable: Bool {
        switch self {
        case .queued, .running, .interrupted:
            return true
        case .done, .failed, .cancelled:
            return false
        }
    }
}
