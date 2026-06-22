public import Foundation

/// The per-PR map of ``PullRequestRef`` to the on-disk git checkout a shepherd's
/// workers should run against.
///
/// ## Why this exists (Bug 1)
/// The reactive seams (``ReviewThreadReactor`` / ``ConversationCommentReactor`` /
/// `CIFixReactor`) carry only a ``PullRequestRef``, never a local path. The
/// production spawner needs the PR's real checkout directory so the worktree it
/// provisions is rooted in an actual git repository. Without this map the spawner
/// fell back to the process's working directory — which is `/` for a launched
/// `.app` — so every worker failed with *"The target directory is not a git
/// repository."*
///
/// When a PR is handed off, the active workspace's directory is recorded here.
/// The spawner's `repoURLResolver` reads it back; a PR with no recorded checkout
/// resolves to `nil`, and the spawner surfaces a clean "nothing done" outcome
/// instead of running an agent in `/`.
///
/// ## Concurrency
/// `actor` — it owns ongoing mutable shared state (the map) read and written from
/// several isolation domains (the `@MainActor` handoff path and the spawner's
/// async resolver), so it is an actor rather than a lock-guarded value.
public actor PRRepositoryDirectoryStore {

    /// The recorded checkout directory per PR, keyed by ``PullRequestRef/id``.
    private var directories: [String: URL] = [:]

    /// Creates an empty store.
    public init() {}

    /// Records (or overwrites) the on-disk checkout directory for a PR.
    ///
    /// - Parameters:
    ///   - directory: The absolute path to the PR's git checkout.
    ///   - pullRequest: The PR being handed off.
    public func record(_ directory: URL, for pullRequest: PullRequestRef) {
        directories[pullRequest.id] = directory
    }

    /// The recorded checkout directory for a PR, or `nil` when none is known.
    ///
    /// - Parameter pullRequest: The PR whose checkout is requested.
    /// - Returns: The recorded directory, or `nil` if the PR was never handed off
    ///   with a directory (the spawner then declines to run rather than use `/`).
    public func directory(for pullRequest: PullRequestRef) -> URL? {
        directories[pullRequest.id]
    }
}
