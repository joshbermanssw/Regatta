/// The per-PR map of ``PullRequestRef`` to the PR's **head branch** — the branch
/// the gate-routed ci-fix push targets (`git push origin HEAD:<headBranch>`).
///
/// ## Why this exists (wrong-push-branch bug)
/// The CI-fix reactor holds only a ``PullRequestRef`` (owner/repo/number), which
/// does **not** carry the head branch. Before this store, `CIFixReactor` built its
/// worker spec with `branch: pullRequest.repo` — the **repository name** — so the
/// gate-approved push went to a junk branch named after the repo (e.g.
/// `HEAD:regatta`) instead of the PR's real branch. The PR therefore never
/// received the fix, its CI never went green, and the loop gave up. The
/// end-to-end pipeline integration test exposed this; this store is the fix.
///
/// When a PR is handed off, the active workspace's current git branch is recorded
/// here. The reactor's `headBranchResolver` reads it back so the push lands on the
/// PR. A PR with no recorded branch resolves to `nil`, and the reactor declines to
/// push to a wrong branch.
///
/// ## Concurrency
/// `actor` — it owns ongoing mutable shared state (the map) read and written from
/// several isolation domains (the `@MainActor` handoff path and the reactor's async
/// resolver), so it is an actor rather than a lock-guarded value.
public actor PRHeadBranchStore {

    /// The recorded head branch per PR, keyed by ``PullRequestRef/id``.
    private var branches: [String: String] = [:]

    /// Creates an empty store.
    public init() {}

    /// Records (or overwrites) the head branch for a PR.
    ///
    /// - Parameters:
    ///   - branch: The PR's head branch (the workspace's current git branch).
    ///   - pullRequest: The PR being handed off.
    public func record(_ branch: String, for pullRequest: PullRequestRef) {
        branches[pullRequest.id] = branch
    }

    /// The recorded head branch for a PR, or `nil` when none is known.
    ///
    /// - Parameter pullRequest: The PR whose head branch is requested.
    /// - Returns: The recorded branch, or `nil` if the PR was never handed off with
    ///   a branch (the reactor then declines to push to a wrong branch).
    public func branch(for pullRequest: PullRequestRef) -> String? {
        branches[pullRequest.id]
    }
}
