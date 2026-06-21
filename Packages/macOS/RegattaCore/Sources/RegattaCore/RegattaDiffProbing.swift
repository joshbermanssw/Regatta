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
}
