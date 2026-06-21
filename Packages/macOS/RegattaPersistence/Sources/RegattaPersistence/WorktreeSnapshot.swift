public import Foundation
public import RegattaCore

/// A `Codable` snapshot of a worker→worktree assignment (issue #34).
///
/// ``RegattaWorktree`` itself is not persisted to disk by
/// ``RegattaWorktreeManager`` (its map is in-memory). This snapshot records the
/// assignment so that, on restore, ``RegattaWorktreeReconciler`` can compare the
/// recorded assignments against what is actually present on disk and drop any
/// that no longer exist.
public struct WorktreeSnapshot: Sendable, Equatable, Codable, Identifiable {
    /// The id of the worker that owns the worktree.
    public let workerID: String

    /// The filesystem path of the worktree root.
    public let path: URL

    /// The git branch checked out in the worktree.
    public let branch: String

    /// The source repository the worktree was created from.
    public let repoURL: URL

    /// Stable identity for `Identifiable` (the worker id).
    public var id: String { workerID }

    /// Creates a worktree snapshot.
    ///
    /// - Parameters:
    ///   - workerID: The owning worker's id.
    ///   - path: The worktree root path.
    ///   - branch: The checked-out branch.
    ///   - repoURL: The source repository URL.
    public init(workerID: String, path: URL, branch: String, repoURL: URL) {
        self.workerID = workerID
        self.path = path
        self.branch = branch
        self.repoURL = repoURL
    }

    /// Captures a ``RegattaWorktree`` into a persistable snapshot.
    ///
    /// - Parameter worktree: The live worktree record.
    public init(worktree: RegattaWorktree) {
        self.init(
            workerID: worktree.workerID,
            path: worktree.path,
            branch: worktree.branch,
            repoURL: worktree.repoURL
        )
    }

    /// Rebuilds a ``RegattaWorktree`` value from this snapshot.
    public func makeWorktree() -> RegattaWorktree {
        RegattaWorktree(workerID: workerID, path: path, branch: branch, repoURL: repoURL)
    }
}
