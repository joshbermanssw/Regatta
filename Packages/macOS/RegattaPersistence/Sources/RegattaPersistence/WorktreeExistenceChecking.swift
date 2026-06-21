public import Foundation

/// An injection seam that answers "does this worktree directory exist on disk?".
///
/// ``RegattaWorktreeReconciler`` depends on `any WorktreeExistenceChecking`
/// rather than touching `FileManager` directly, so tests can reconcile against a
/// deterministic in-memory set with no real filesystem.
public protocol WorktreeExistenceChecking: Sendable {
    /// Returns whether a worktree directory exists at `url`.
    ///
    /// - Parameter url: The worktree root path to check.
    /// - Returns: `true` if a directory exists at `url`.
    func worktreeExists(at url: URL) -> Bool
}

/// The production ``WorktreeExistenceChecking`` backed by `FileManager`.
///
/// A path is considered a live worktree only when it exists *and* is a directory,
/// so a stale file at the recorded path does not count.
public struct FileManagerWorktreeExistenceChecker: WorktreeExistenceChecking {
    /// Creates a checker backed by `FileManager.default`.
    public init() {}

    public func worktreeExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
