public import RegattaCore

/// Pure restore-semantics transforms applied to a loaded ``RegattaStateSnapshot``
/// (issue #34, session restore).
///
/// The planner holds no state and performs no I/O — it maps a persisted snapshot
/// into the *restored* values the app should adopt on launch. Splitting these
/// rules out as pure functions on a value type keeps them trivially testable and
/// keeps the live wiring (Fleet, orchestrator, worktree manager) free of restore
/// branching.
///
/// ## Worker restore rule
///
/// A worker's live agent process cannot be resumed across a restart. Any worker
/// that was non-terminal when persisted (``RegattaCore/WorkerStatus/queued`` or
/// ``RegattaCore/WorkerStatus/running``) is restored as
/// ``RegattaCore/WorkerStatus/interrupted`` so the Fleet UI offers to relaunch
/// it. Terminal workers (`done`, `failed`, `cancelled`) keep their status, and an
/// already-`interrupted` worker stays interrupted.
///
/// ## Loop restore rule
///
/// A loop's configuration and full iteration history are restored verbatim, but a
/// loop that was ``RegattaCore/RegattaLoopStatus/running`` cannot keep iterating
/// without its worker, so its status is mapped to
/// ``RegattaCore/RegattaLoopStatus/idle`` (re-armed, ready to relaunch). Terminal
/// and idle loop statuses are preserved.
public struct RegattaRestorePlanner: Sendable {

    /// Creates a restore planner.
    public init() {}

    /// Maps a persisted ``WorkerStatus`` to the status to adopt on restore.
    ///
    /// - Parameter status: The persisted last-known status.
    /// - Returns: ``RegattaCore/WorkerStatus/interrupted`` for a previously-live
    ///   worker; the original status otherwise.
    public func restoredWorkerStatus(from status: WorkerStatus) -> WorkerStatus {
        switch status {
        case .queued, .running:
            return .interrupted
        case .done, .failed, .cancelled, .interrupted:
            return status
        }
    }

    /// Maps a persisted ``RegattaLoopStatus`` to the status to adopt on restore.
    ///
    /// - Parameter status: The persisted loop status.
    /// - Returns: ``RegattaCore/RegattaLoopStatus/idle`` for a previously-running
    ///   loop; the original status otherwise.
    public func restoredLoopStatus(from status: RegattaLoopStatus) -> RegattaLoopStatus {
        switch status {
        case .running:
            return .idle
        case .idle, .stopped, .failed:
            return status
        }
    }

    /// Returns the workers from a snapshot with the worker restore rule applied.
    ///
    /// - Parameter snapshot: The loaded state snapshot.
    /// - Returns: Worker snapshots whose live statuses have been mapped to
    ///   ``RegattaCore/WorkerStatus/interrupted``.
    public func restoredWorkers(from snapshot: RegattaStateSnapshot) -> [WorkerSnapshot] {
        snapshot.workers.map { worker in
            WorkerSnapshot(
                id: worker.id,
                name: worker.name,
                prompt: worker.prompt,
                status: restoredWorkerStatus(from: worker.status),
                providerID: worker.providerID
            )
        }
    }

    /// Returns the loops from a snapshot with the loop restore rule applied.
    ///
    /// - Parameter snapshot: The loaded state snapshot.
    /// - Returns: Loop snapshots whose running status has been re-armed to
    ///   ``RegattaCore/RegattaLoopStatus/idle`` while config + history are kept.
    public func restoredLoops(from snapshot: RegattaStateSnapshot) -> [LoopSnapshot] {
        snapshot.loops.map { loop in
            let restoredState = RegattaLoopState(
                configuration: loop.state.configuration,
                status: restoredLoopStatus(from: loop.state.status),
                history: loop.state.history
            )
            return LoopSnapshot(workerID: loop.workerID, state: restoredState)
        }
    }
}
