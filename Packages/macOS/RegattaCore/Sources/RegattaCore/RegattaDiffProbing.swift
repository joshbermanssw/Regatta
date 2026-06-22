public import Foundation

/// The seam the `dry` stop condition uses to ask "did this iteration produce any
/// new changes?".
///
/// The production conformer (``RegattaGitDiffProbe``) runs `git status` in the
/// worker's worktree; tests can stub it to drive the dry condition without a
/// real repo when they want to, while the integration tests use the real probe
/// against a temp git repo. Injecting this seam keeps ``RegattaDryWorker``
/// testable per the architecture rules.
public protocol RegattaDiffProbing: Sendable {
    /// Reports whether the given worktree currently has uncommitted changes
    /// (tracked modifications, staged changes, or untracked files).
    ///
    /// - Parameter worktreePath: The root of the git worktree to inspect.
    /// - Returns: `true` if the worktree is dirty, `false` if it is clean.
    /// - Throws: A subprocess or git error if the status check fails.
    func hasUncommittedChanges(at worktreePath: URL) async throws -> Bool

    /// Reports whether the given worktree's branch has **new local commits** that
    /// exist on it but on no other branch in the repository.
    ///
    /// This is the "the agent committed locally (but did not push)" signal the
    /// Fleet reactors use to decide that a worker *produced changes worth
    /// pushing*. Because a worker worktree is created with `git worktree add -b
    /// <branch>` forked from the repo's HEAD, any commit the agent makes lands on
    /// `<branch>` and is reachable from no other branch — so counting commits
    /// unique to this branch detects the agent's work even though it left the
    /// worktree *clean* (committed, not dirty).
    ///
    /// - Parameter worktreePath: The root of the git worktree to inspect.
    /// - Returns: `true` if the worktree's branch has at least one commit not
    ///   reachable from any other branch.
    /// - Throws: A subprocess or git error if the inspection fails.
    func hasNewCommits(at worktreePath: URL) async throws -> Bool
}

extension RegattaDiffProbing {
    /// Default: a probe that only models the working-tree dirtiness reports no new
    /// commits. Real probes (``RegattaGitDiffProbe``) override this with a `git
    /// rev-list` check so existing stub conformers keep compiling unchanged.
    public func hasNewCommits(at worktreePath: URL) async throws -> Bool { false }

    /// Reports whether the worker produced any work worth pushing this iteration:
    /// either it left **uncommitted** changes in the worktree *or* it made **new
    /// local commits**. Reactors use this single signal so a worker that commits
    /// (the autonomy-preserving path: agent commits, Regatta pushes) is correctly
    /// detected as "produced changes" — the bug where committing made the worktree
    /// clean and the loop saw "no fix".
    ///
    /// - Parameter worktreePath: The root of the git worktree to inspect.
    /// - Returns: `true` if there are uncommitted changes or new local commits.
    /// - Throws: A subprocess or git error if either inspection fails.
    public func hasProducedWork(at worktreePath: URL) async throws -> Bool {
        if try await hasUncommittedChanges(at: worktreePath) { return true }
        return try await hasNewCommits(at: worktreePath)
    }
}
