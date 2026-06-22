public import Foundation

/// The per-PR map of ``PullRequestRef`` to the worktree of the most recent ci-fix
/// worker that produced commits for it.
///
/// ## Why this exists (gate-routed push)
/// Workers are prompted to *commit locally, not push*; the actual push is routed
/// through the ``AutonomyGate`` and performed by ``GitPushActionExecutor``. That
/// executor needs to know **which worktree** to `git push` — the throwaway
/// worktree the ci-fix worker just committed into (each worker gets its own
/// `regatta/worker-<id>` worktree). The ci-fix worker handle records that
/// worktree here when it finishes producing work, and the push executor's
/// resolver reads it back, so the gate-approved push lands exactly the commits the
/// agent made.
///
/// A PR with no recorded worktree resolves to `nil`, and the push executor fails
/// with ``GitPushActionError/noWorktree`` rather than pushing the wrong tree.
///
/// ## Concurrency
/// `actor` — it owns ongoing mutable shared state (the map) read and written from
/// several isolation domains (the worker handle and the push executor's async
/// resolver), so it is an actor rather than a lock-guarded value.
public actor CIFixWorktreeStore {

    /// The recorded worktree path per PR, keyed by ``PullRequestRef/id``.
    private var worktrees: [String: URL] = [:]

    /// Creates an empty store.
    public init() {}

    /// Records (or overwrites) the worktree a ci-fix worker committed into for a
    /// PR, so a later gate-approved push targets it.
    ///
    /// - Parameters:
    ///   - worktreePath: The worktree the worker committed its fix into.
    ///   - pullRequest: The PR the worker is fixing.
    public func record(_ worktreePath: URL, for pullRequest: PullRequestRef) {
        worktrees[pullRequest.id] = worktreePath
    }

    /// The recorded worktree for a PR, or `nil` when none is known.
    ///
    /// - Parameter pullRequest: The PR whose latest ci-fix worktree is requested.
    /// - Returns: The recorded worktree path, or `nil` if no ci-fix worker has
    ///   recorded one for this PR.
    public func worktree(for pullRequest: PullRequestRef) -> URL? {
        worktrees[pullRequest.id]
    }
}
