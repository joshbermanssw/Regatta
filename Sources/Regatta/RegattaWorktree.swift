import Foundation

/// A value record describing a git worktree provisioned for a specific worker.
struct RegattaWorktree: Equatable, Sendable {
    /// The identifier of the worker that owns this worktree.
    let workerID: String

    /// The filesystem path of the worktree root.
    let path: URL

    /// The git branch checked out in this worktree.
    let branch: String

    /// The URL of the source git repository from which the worktree was created.
    let repoURL: URL
}
