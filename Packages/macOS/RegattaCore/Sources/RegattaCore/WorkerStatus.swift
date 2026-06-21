/// The lifecycle status of a Fleet worker, reflected by a status dot in the UI.
///
/// Transitions follow the real process lifecycle driven by the orchestrator:
/// `.queued` → `.running` → (`.done` | `.failed` | `.blocked` | `.cancelled`).
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

    /// The worker is parked awaiting human resolution and made no destructive
    /// change — e.g. its worktree could not be provisioned or cleaned up because
    /// of a conflict (issue #35). Unlike ``failed``, a blocked worker represents a
    /// *recoverable* situation: the work product (worktree, branch) is intact and
    /// the human is expected to resolve the conflict, after which the worker can be
    /// retried or cancelled. The associated value is a human-readable reason.
    ///
    /// `blocked` is a terminal status for the orchestrator's own scheduling (it
    /// frees the run slot and is never auto-resumed), but it is still cancellable
    /// so the human can dismiss it from the Fleet once they have resolved the
    /// conflict.
    case blocked(String)

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
        case .done, .failed, .blocked, .cancelled:
            return true
        }
    }

    /// Whether the worker can be cancelled in its current state.
    ///
    /// A ``blocked`` worker is cancellable so the human can clear it once they
    /// have resolved the underlying conflict. An ``interrupted`` worker is
    /// cancellable so the human can dismiss a restored, never-relaunched worker.
    public var isCancellable: Bool {
        switch self {
        case .queued, .running, .blocked, .interrupted:
            return true
        case .done, .failed, .cancelled:
            return false
        }
    }

    /// Whether this status counts as a failed iteration for the brain's
    /// bookkeeping (issue #35: a crash counts as a failed iteration).
    ///
    /// ``failed`` counts as a failure; ``blocked`` does not, because the worker
    /// made no destructive change and is awaiting human resolution rather than
    /// having genuinely failed its goal.
    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
