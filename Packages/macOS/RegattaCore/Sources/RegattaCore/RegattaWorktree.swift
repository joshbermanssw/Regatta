public import Foundation

/// A value record describing a git worktree provisioned for a specific worker.
public struct RegattaWorktree: Equatable, Sendable {
    /// The identifier of the worker that owns this worktree.
    public let workerID: String

    /// The filesystem path of the worktree root.
    public let path: URL

    /// The git branch checked out in this worktree.
    public let branch: String

    /// The URL of the source git repository from which the worktree was created.
    public let repoURL: URL

    /// Creates a new `RegattaWorktree` record.
    ///
    /// - Parameters:
    ///   - workerID: The identifier of the worker that owns this worktree.
    ///   - path: The filesystem path of the worktree root.
    ///   - branch: The git branch checked out in this worktree.
    ///   - repoURL: The URL of the source git repository from which the worktree was created.
    public init(workerID: String, path: URL, branch: String, repoURL: URL) {
        self.workerID = workerID
        self.path = path
        self.branch = branch
        self.repoURL = repoURL
    }
}
