public import Foundation

/// Errors thrown by ``RegattaWorktreeManager``.
public enum WorktreeError: Error, CustomStringConvertible {
    /// The given URL is not a git repository (or is not inside one).
    case notAGitRepository

    /// The worktree at the given path has uncommitted changes and `force` was not passed.
    case worktreeDirty(path: URL)

    /// No worktree is tracked for the requested worker ID.
    case noWorktreeForWorker(String)

    /// A worktree is already tracked for the given worker ID.
    case worktreeAlreadyExists(workerID: String)

    /// A git command exited with a non-zero status.
    case gitCommandFailed(command: String, exitCode: Int32, stderr: String)

    /// Whether this error represents a *recoverable worktree conflict* a human is
    /// expected to resolve, rather than an outright failure (issue #35).
    ///
    /// A conflict is one where the work product is intact and colliding with
    /// existing state: an already-tracked worktree for the worker, a dirty
    /// worktree that refused force-free cleanup, or a `git worktree add` / branch
    /// collision (e.g. the target path or branch already exists). The orchestrator
    /// parks such a worker as ``WorkerStatus/blocked(_:)`` for human resolution
    /// instead of marking it ``WorkerStatus/failed(_:)``, so no data is lost.
    public var isConflict: Bool {
        switch self {
        case .worktreeAlreadyExists, .worktreeDirty:
            return true
        case .gitCommandFailed(let command, _, let stderr):
            // `git worktree add` collisions and branch-already-exists are
            // conflicts a human resolves; other git failures are genuine errors.
            let lowered = stderr.lowercased()
            let collided = lowered.contains("already exists")
                || lowered.contains("already used by worktree")
                || lowered.contains("is already checked out")
            return command == "worktree" || collided
        case .notAGitRepository, .noWorktreeForWorker:
            return false
        }
    }

    public var description: String {
        switch self {
        case .notAGitRepository:
            return "The target directory is not a git repository."
        case .worktreeDirty(let path):
            return "Worktree at \(path.path) has uncommitted changes. Pass force: true to remove it anyway."
        case .noWorktreeForWorker(let workerID):
            return "No worktree is tracked for worker '\(workerID)'."
        case .worktreeAlreadyExists(let workerID):
            return "A worktree is already tracked for worker '\(workerID)'."
        case .gitCommandFailed(let command, let exitCode, let stderr):
            return "git command '\(command)' failed with exit code \(exitCode): \(stderr)"
        }
    }
}
