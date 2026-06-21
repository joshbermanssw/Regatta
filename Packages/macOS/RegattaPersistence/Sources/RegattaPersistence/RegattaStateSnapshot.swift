public import RegattaFleet

/// The complete, `Codable` snapshot of Regatta's restorable state (issue #34).
///
/// This is the single value written to and read from disk by
/// ``RegattaStateStore``. It deliberately excludes the memory tree + facts:
/// those are already persisted independently by `RegattaMemory.MemoryStore`, and
/// duplicating them here would create two sources of truth. On launch the memory
/// store loads itself; ``RegattaStateStore`` restores everything else.
///
/// What it carries:
/// - **Workers** — definitions + last-known status (live processes are not
///   resumed; restored as ``RegattaCore/WorkerStatus/interrupted``).
/// - **Loops** — configuration + full iteration history per worker.
/// - **Shepherds** — the last-known ``RegattaFleet/ShepherdState`` per watched
///   PR; on restore each resumes polling automatically.
/// - **Autonomy modes** — the per-PR ``RegattaFleet/AutonomyMode`` so a user's
///   staged/auto choice survives a restart, keyed by PR id.
/// - **Worktrees** — worker→worktree assignments, reconciled against disk on
///   restore.
public struct RegattaStateSnapshot: Sendable, Equatable, Codable {
    /// Fleet worker definitions + last-known status.
    public var workers: [WorkerSnapshot]

    /// Loop configuration + iteration history, one per worker id.
    public var loops: [LoopSnapshot]

    /// The last-known shepherd snapshot per watched PR.
    public var shepherds: [ShepherdState]

    /// Per-PR autonomy mode, keyed by ``RegattaFleet/PullRequestRef/id``.
    ///
    /// Kept separately from ``shepherds`` so a user's autonomy choice persists
    /// even if no shepherd snapshot was captured for that PR yet.
    public var autonomyModes: [String: AutonomyMode]

    /// Worker→worktree assignments to reconcile with disk on restore.
    public var worktrees: [WorktreeSnapshot]

    /// Creates a state snapshot.
    ///
    /// All parameters default to empty so callers can build a snapshot
    /// incrementally.
    public init(
        workers: [WorkerSnapshot] = [],
        loops: [LoopSnapshot] = [],
        shepherds: [ShepherdState] = [],
        autonomyModes: [String: AutonomyMode] = [:],
        worktrees: [WorktreeSnapshot] = []
    ) {
        self.workers = workers
        self.loops = loops
        self.shepherds = shepherds
        self.autonomyModes = autonomyModes
        self.worktrees = worktrees
    }

    /// An empty snapshot (the state of a fresh install with nothing persisted).
    public static var empty: RegattaStateSnapshot { RegattaStateSnapshot() }
}
