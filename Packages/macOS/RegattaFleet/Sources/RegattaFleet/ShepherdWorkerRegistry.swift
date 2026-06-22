public import Foundation
public import RegattaGitHub

/// Tracks which ephemeral workers each shepherd (PR) currently owns, so that
/// dismissing a shepherd can cascade-cancel exactly the workers it spawned.
///
/// ## Why this exists
/// Reactive layers spawn ephemeral workers scoped to a PR: the ci-fix loop's
/// per-iteration worker, and the review-thread / conversation-comment /
/// review-summary addressing workers. Before this registry, dismissing a shepherd
/// only stopped its poll watcher — any in-flight worker (and the ci-fix loop that
/// keeps spawning them) kept running orphaned, the runaway the user dogfooded
/// ("dismissing the shepherd did NOT stop the loops"). The spawn path records
/// each worker's id here under its PR while it runs and clears it on termination;
/// the dismiss cascade reads ``workerIDs(for:)`` and cancels each one.
///
/// ## Concurrency
/// `actor` — owns mutable shared ownership state read/written from several
/// isolation domains (each spawn task and the dismiss path).
public actor ShepherdWorkerRegistry {

    /// Running worker ids per PR, keyed by ``PullRequestRef/id``.
    private var workers: [String: Set<UUID>] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Records that `workerID` is now running for `pullRequest`.
    public func record(_ workerID: UUID, for pullRequest: PullRequestRef) {
        workers[pullRequest.id, default: []].insert(workerID)
    }

    /// Clears `workerID` from `pullRequest`'s owned set once it terminates.
    public func clear(_ workerID: UUID, for pullRequest: PullRequestRef) {
        workers[pullRequest.id]?.remove(workerID)
        if workers[pullRequest.id]?.isEmpty == true {
            workers[pullRequest.id] = nil
        }
    }

    /// The worker ids currently owned by `pullRequest`, for a dismiss cascade.
    public func workerIDs(for pullRequest: PullRequestRef) -> [UUID] {
        Array(workers[pullRequest.id] ?? [])
    }

    /// Drops all ownership records for `pullRequest` (after a dismiss cascade has
    /// cancelled them), so a re-handoff starts clean.
    public func removeAll(for pullRequest: PullRequestRef) {
        workers[pullRequest.id] = nil
    }
}
