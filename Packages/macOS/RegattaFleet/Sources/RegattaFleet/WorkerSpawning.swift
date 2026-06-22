public import RegattaGitHub

/// The result of one ci-fix worker iteration, as the loop sees it.
///
/// Distinguishes the three outcomes the fix loop must react to differently:
/// - ``produced``: the worker made local commits worth pushing → push + re-poll.
/// - ``noFix``: the worker ran but produced nothing → no-progress stop.
/// - ``cancelled``: the worker was **cancelled or killed** (a user ✕ from the
///   Fleet, a shepherd-dismiss cascade, or a SIGTERM/SIGKILL from cancellation)
///   → the loop must STOP and never spawn another iteration. A user cancel means
///   "stop", never "retry"; conflating it with ``noFix`` (which is also a stop
///   but flags needs-attention) would mislabel a deliberate cancel.
public enum CIFixAttemptOutcome: Sendable, Equatable {
    /// The worker made local commits that should be pushed.
    case produced
    /// The worker ran but could not produce a fix this iteration.
    case noFix
    /// The worker was cancelled or killed — a final stop, never a retry.
    case cancelled
}

/// A handle to a spawned `ci-fix` worker.
///
/// Returned by ``WorkerSpawning/spawn(_:)`` so the reactor can later ask the
/// worker to attempt a fix and learn whether it produced any changes. The real
/// orchestrator (#14/#16) backs this with a pane/agent session; the reactor only
/// depends on this minimal contract.
public protocol CIFixWorkerHandle: Sendable {
    /// Stable identity matching the originating ``CIFixWorkerSpec/id``.
    var id: String { get }

    /// Drives one fix attempt and reports how it concluded.
    ///
    /// - Returns: ``CIFixAttemptOutcome/produced`` when the worker made local
    ///   commits that should be pushed; ``CIFixAttemptOutcome/noFix`` when it
    ///   could not produce a fix; ``CIFixAttemptOutcome/cancelled`` when the
    ///   worker was cancelled or killed (the loop must then stop, not respawn).
    func attemptFix() async -> CIFixAttemptOutcome
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

/// A request to spawn an ephemeral worker that addresses one top-level PR
/// conversation comment (ARMADA-style "comment on the PR → a worker addresses
/// it").
///
/// Carries the context an addressing agent needs: which PR and the conversation
/// comment that triggered it. The orchestrator turns this into a live agent pane;
/// a stub spawner records the request in tests.
public struct ConversationCommentWorkRequest: Sendable, Equatable {
    /// The pull request whose conversation comment is being addressed.
    public let pullRequest: PullRequestRef
    /// The conversation comment the worker must address.
    public let comment: PRConversationComment

    /// Creates a work request.
    /// - Parameters:
    ///   - pullRequest: The PR the comment belongs to.
    ///   - comment: The comment to address.
    public init(pullRequest: PullRequestRef, comment: PRConversationComment) {
        self.pullRequest = pullRequest
        self.comment = comment
    }
}

/// The outcome of an addressing worker run for a conversation comment.
///
/// The reactor uses this to decide whether to post a reply once the worker
/// finishes. Unlike a review thread there is nothing to "resolve" — a
/// conversation comment is just a timeline entry — so the result models only the
/// pushed-change and reply signals.
public struct ConversationCommentWorkResult: Sendable, Equatable {
    /// Whether the worker pushed a code change addressing the comment.
    public let pushedCodeChange: Bool
    /// An optional reply to post in the conversation, or `nil` to post none.
    public let replyBody: String?

    /// Creates a work result.
    /// - Parameters:
    ///   - pushedCodeChange: Whether code was pushed.
    ///   - replyBody: Reply to post, or `nil` for none.
    public init(pushedCodeChange: Bool, replyBody: String?) {
        self.pushedCodeChange = pushedCodeChange
        self.replyBody = replyBody
    }
}

/// A request to spawn an ephemeral worker that addresses one reviewer's
/// submitted review (review summary) — the Approve / Request changes / Comment
/// note a reviewer left when submitting their review.
///
/// Carries the context an addressing agent needs: which PR and the review that
/// triggered it. The orchestrator turns this into a live agent pane; a stub
/// spawner records the request in tests.
public struct ReviewSummaryWorkRequest: Sendable, Equatable {
    /// The pull request whose review is being addressed.
    public let pullRequest: PullRequestRef
    /// The review the worker must address.
    public let review: PRReview

    /// Creates a work request.
    /// - Parameters:
    ///   - pullRequest: The PR the review belongs to.
    ///   - review: The review to address.
    public init(pullRequest: PullRequestRef, review: PRReview) {
        self.pullRequest = pullRequest
        self.review = review
    }
}

/// The outcome of an addressing worker run for a review summary.
///
/// The reactor uses this to decide whether to post a reply once the worker
/// finishes. A pure approval typically yields nothing to do — the worker reports
/// no pushed change and no reply, and the reactor posts nothing ("nothing done").
public struct ReviewSummaryWorkResult: Sendable, Equatable {
    /// Whether the worker pushed a code change addressing the review.
    public let pushedCodeChange: Bool
    /// An optional reply to post on the PR, or `nil` to post none (e.g. when the
    /// review is a pure approval with nothing to address).
    public let replyBody: String?

    /// Creates a work result.
    /// - Parameters:
    ///   - pushedCodeChange: Whether code was pushed.
    ///   - replyBody: Reply to post, or `nil` for none.
    public init(pushedCodeChange: Bool, replyBody: String?) {
        self.pushedCodeChange = pushedCodeChange
        self.replyBody = replyBody
    }
}

/// The single injection seam for spawning Fleet workers, mirroring the pane
/// bridge / orchestrator from issues #14 and #16.
///
/// All reactive layers spawn agent workers through this one seam: the ci-fix
/// loop (#30) spawns a `ci-fix` worker scoped to a PR branch, the review-thread
/// handler (#31) spawns an addressing worker scoped to a single thread, the
/// conversation-comment handler spawns an addressing worker scoped to one
/// top-level PR comment, and the review-summary handler spawns an addressing
/// worker scoped to one submitted review. Depending on `any WorkerSpawning` lets
/// each ship and be tested independently; the production spawner is wired when
/// the orchestrator lands, and tests inject stubs.
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

    /// Spawns a worker to address a top-level PR conversation comment and awaits
    /// its result.
    ///
    /// - Parameter request: The conversation-comment context to address.
    /// - Returns: The worker's outcome — whether it pushed code and what reply to
    ///   post.
    /// - Throws: Any error the underlying spawn/agent run surfaces; the reactor
    ///   treats a throw as "comment not handled" so it can be retried.
    func spawnWorker(for request: ConversationCommentWorkRequest) async throws -> ConversationCommentWorkResult

    /// Spawns a worker to address a reviewer's submitted review (review summary)
    /// and awaits its result.
    ///
    /// - Parameter request: The review context to address.
    /// - Returns: The worker's outcome — whether it pushed code and what reply to
    ///   post. A pure approval typically yields nothing to do.
    /// - Throws: Any error the underlying spawn/agent run surfaces; the reactor
    ///   treats a throw as "review not handled" so it can be retried.
    func spawnWorker(for request: ReviewSummaryWorkRequest) async throws -> ReviewSummaryWorkResult
}
