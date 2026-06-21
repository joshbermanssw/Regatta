public import RegattaGitHub

/// The spawn request for a `ci-fix` worker scoped to one pull request.
///
/// A `ci-fix` worker runs against the PR's own branch/worktree so the fixes it
/// produces land on that branch. The orchestrator (#14/#16) is responsible for
/// materialising the worktree and launching the agent; this value carries the
/// minimum it needs.
public struct CIFixWorkerSpec: Sendable, Equatable, Identifiable {
    /// The pull request whose failing CI this worker is fixing.
    public let pullRequest: PullRequestRef

    /// The git branch the worker checks out and pushes to (the PR head branch).
    public let branch: String

    /// Stable identity for the worker, derived from the PR. Reusing the PR
    /// identity keeps repeated spawns for the same PR idempotent at the
    /// orchestrator boundary.
    public var id: String { "ci-fix:\(pullRequest.id)" }

    /// Creates a `ci-fix` worker spec.
    ///
    /// - Parameters:
    ///   - pullRequest: The PR whose CI is failing.
    ///   - branch: The PR head branch the worker operates on.
    public init(pullRequest: PullRequestRef, branch: String) {
        self.pullRequest = pullRequest
        self.branch = branch
    }
}
