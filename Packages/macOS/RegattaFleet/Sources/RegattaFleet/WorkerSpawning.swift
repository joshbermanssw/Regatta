public import RegattaGitHub

/// A handle to a spawned `ci-fix` worker.
///
/// Returned by ``WorkerSpawning/spawn(_:)`` so the reactor can later ask the
/// worker to attempt a fix and learn whether it produced any changes. The real
/// orchestrator (#14/#16) backs this with a pane/agent session; the reactor only
/// depends on this minimal contract.
public protocol CIFixWorkerHandle: Sendable {
    /// Stable identity matching the originating ``CIFixWorkerSpec/id``.
    var id: String { get }

    /// Drives one fix attempt and reports whether the worker produced changes
    /// worth pushing.
    ///
    /// - Returns: `true` when the worker made local commits that should be
    ///   pushed; `false` when it could not produce a fix this iteration.
    func attemptFix() async -> Bool
}

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

/// The single injection seam for spawning Fleet workers, mirroring the pane
/// bridge / orchestrator from issues #14 and #16.
///
/// Both reactive layers spawn agent workers through this one seam: the ci-fix
/// loop (#30) spawns a `ci-fix` worker scoped to a PR branch, and the
/// review-thread handler (#31) spawns an addressing worker scoped to a single
/// thread. Depending on `any WorkerSpawning` lets both ship and be tested
/// independently; the production spawner is wired when the orchestrator lands,
/// and tests inject stubs.
public protocol WorkerSpawning: Sendable {
    /// Spawns a `ci-fix` worker scoped to the spec's PR branch/worktree (#30).
    ///
    /// - Parameter spec: The worker request describing the PR and branch.
    /// - Returns: A handle to drive and observe the spawned worker.
    func spawn(_ spec: CIFixWorkerSpec) async -> any CIFixWorkerHandle

    /// Spawns a worker to address a review thread and awaits its result (#31).
    ///
    /// - Parameter request: The thread context to address.
    /// - Returns: The worker's outcome — whether it pushed code, what reply to
    ///   post, and whether to resolve.
    /// - Throws: Any error the underlying spawn/agent run surfaces; the reactor
    ///   treats a throw as "thread not handled" so it can be retried.
    func spawnWorker(for request: ReviewThreadWorkRequest) async throws -> ReviewThreadWorkResult
}
