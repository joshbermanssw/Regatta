import Foundation

/// Errors thrown by ``RegattaWorktreeManager``.
enum WorktreeError: Error, CustomStringConvertible {
    /// The given URL is not a git repository (or is not inside one).
    case notAGitRepository

    /// The worktree at the given path has uncommitted changes and `force` was not passed.
    case worktreeDirty(path: URL)

    /// No worktree is tracked for the requested worker ID.
    case noWorktreeForWorker(String)

    /// A git command exited with a non-zero status.
    case gitCommandFailed(command: String, exitCode: Int32, stderr: String)

    var description: String {
        switch self {
        case .notAGitRepository:
            return "The target directory is not a git repository."
        case .worktreeDirty(let path):
            return "Worktree at \(path.path) has uncommitted changes. Pass force: true to remove it anyway."
        case .noWorktreeForWorker(let workerID):
            return "No worktree is tracked for worker '\(workerID)'."
        case .gitCommandFailed(let command, let exitCode, let stderr):
            return "git command '\(command)' failed with exit code \(exitCode): \(stderr)"
        }
    }
}
