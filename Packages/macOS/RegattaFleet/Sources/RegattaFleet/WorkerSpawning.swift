public import RegattaGitHub

/// A request to spawn an ephemeral worker that addresses one review thread.
///
/// Carries the context an addressing agent needs: which PR, which thread, and
/// the reviewer comment text that triggered it. The orchestrator (issue #16)
/// turns this into a live agent pane; until then a stub spawner records the
/// request.
public struct ReviewThreadWorkRequest: Sendable, Equatable {
    /// The pull request whose thread is being addressed.
    public let pullRequest: PullRequestRef
    /// The review thread the worker must address.
    public let thread: ReviewThread

    /// Creates a work request.
    /// - Parameters:
    ///   - pullRequest: The PR the thread belongs to.
    ///   - thread: The thread to address.
    public init(pullRequest: PullRequestRef, thread: ReviewThread) {
        self.pullRequest = pullRequest
        self.thread = thread
    }
}

/// The outcome of an addressing worker run.
///
/// The reactor uses this to decide whether to post a reply and/or resolve the
/// thread once the worker finishes.
public struct ReviewThreadWorkResult: Sendable, Equatable {
    /// Whether the worker pushed a code change addressing the thread.
    public let pushedCodeChange: Bool
    /// An optional reply to post on the thread (e.g. explaining the change), or
    /// `nil` to post no reply.
    public let replyBody: String?
    /// Whether the thread should be resolved on completion.
    public let shouldResolve: Bool

    /// Creates a work result.
    /// - Parameters:
    ///   - pushedCodeChange: Whether code was pushed.
    ///   - replyBody: Reply to post, or `nil` for none.
    ///   - shouldResolve: Whether to resolve the thread.
    public init(pushedCodeChange: Bool, replyBody: String?, shouldResolve: Bool) {
        self.pushedCodeChange = pushedCodeChange
        self.replyBody = replyBody
        self.shouldResolve = shouldResolve
    }
}

/// The injection seam for spawning the worker that addresses a review thread.
///
/// Spawning a live addressing agent needs the orchestrator / pane bridge from
/// issues #16 and #14, which are not yet merged. Depending on `any
/// WorkerSpawning` lets the review-thread reactor ship now: the production
/// spawner is wired when #16 lands, and tests inject a stub that returns a
/// canned ``ReviewThreadWorkResult`` without launching anything.
///
/// ```swift
/// // Tests
/// let spawner: any WorkerSpawning = StubWorkerSpawner(
///     result: ReviewThreadWorkResult(pushedCodeChange: true, replyBody: "Fixed.", shouldResolve: true)
/// )
/// ```
public protocol WorkerSpawning: Sendable {
    /// Spawns a worker to address a review thread and awaits its result.
    ///
    /// - Parameter request: The thread context to address.
    /// - Returns: The worker's outcome — whether it pushed code, what reply to
    ///   post, and whether to resolve.
    /// - Throws: Any error the underlying spawn/agent run surfaces; the reactor
    ///   treats a throw as "thread not handled" so it can be retried.
    func spawnWorker(for request: ReviewThreadWorkRequest) async throws -> ReviewThreadWorkResult
}
