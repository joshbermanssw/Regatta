public import RegattaGitHub

/// The reactive layer that turns new PR conversation comments into addressing
/// work (ARMADA-style "comment on the PR → the shepherd spawns a worker").
///
/// A `ConversationCommentReactor` observes a shepherd's successive
/// ``ShepherdState`` snapshots and, each time a poll reveals a top-level PR
/// conversation comment it has not yet handled — **and that the shepherd did not
/// author itself** — dispatches a ``ConversationCommentWorker`` to address it
/// (push a change and/or post a reply).
///
/// ## Self-reply loop prevention (core correctness requirement)
/// The shepherd's own reply is *itself* a conversation comment, so reacting to
/// every new comment naively would make the shepherd answer its own answers
/// forever. To prevent this the reactor resolves the authenticated `gh` user's
/// login once (via the injected ``selfLogin`` provider, cached after the first
/// non-empty result) and **skips every comment authored by that login**. The
/// handled-id set is a second, independent guard ensuring each comment is acted
/// on at most once even across rapid polls; the self-author filter is what stops
/// the loop, and is tested explicitly.
///
/// ## New-comment detection
/// "New comment" is detected by diffing successive `conversationComments` polls
/// against the set of comment IDs already handled (and those currently in
/// flight). A comment is **actionable** when it has a non-empty body and its
/// author is actionable: it is **not** authored by the shepherd / current user,
/// **not** authored by a bot (login ending in `[bot]`, e.g. `vercel[bot]`), and
/// the current user has **not already replied after it** (already-answered
/// guard).
///
/// ## Idempotency
/// Each comment id is handled **once**. The reactor records a comment id as
/// handled only when its worker reports the comment was *fully* handled; a
/// comment whose worker was suppressed by the autonomy gate or that failed is
/// left unrecorded so the next poll retries it. In-flight ids are also tracked so
/// two rapid polls cannot spawn two workers for the same comment.
///
/// ## Concurrency
/// `actor` — the handled / in-flight id sets and the cached login are
/// actor-isolated. ``observe(_:)`` drives the reactor from a watcher's
/// `AsyncStream`; ``react(to:)`` processes one snapshot and is exposed so tests
/// can drive exactly one diff deterministically.
public actor ConversationCommentReactor {
    private let worker: ConversationCommentWorker

    /// Resolves the authenticated `gh` user's login. Returns `nil` when the
    /// lookup fails; the reactor then conservatively treats no comment as
    /// self-authored for that poll (it relies on the handled-id set to avoid
    /// duplicates and retries the login on the next poll).
    private let selfLogin: @Sendable () async -> String?

    /// The cached self-login, resolved on first successful lookup.
    private var cachedSelfLogin: String?

    /// Comment IDs that have been fully handled; never re-dispatched.
    private var handled: Set<String> = []
    /// Comment IDs with a worker currently in flight; guards against a second
    /// poll dispatching a duplicate before the first finishes.
    private var inFlight: Set<String> = []

    /// Handled comment IDs grouped by PR id, so ``forget(for:)`` clears exactly one
    /// PR's set without disturbing other PRs (the reactor is shared app-wide).
    private var handledByPR: [String: Set<String>] = [:]

    /// PRs whose shepherd was dismissed; their snapshots are ignored until a fresh
    /// handoff re-arms them (``rearm(for:)``), so a late snapshot cannot re-trigger
    /// dismissed work (I2).
    private var dismissed: Set<String> = []

    /// Creates a reactor that dispatches the given worker.
    ///
    /// - Parameters:
    ///   - worker: The per-comment worker used to address each new comment.
    ///   - selfLogin: Resolves the authenticated `gh` user's login for the
    ///     self-author loop guard.
    public init(
        worker: ConversationCommentWorker,
        selfLogin: @escaping @Sendable () async -> String?
    ) {
        self.worker = worker
        self.selfLogin = selfLogin
    }

    /// Convenience initializer that assembles the worker from its seams.
    ///
    /// - Parameters:
    ///   - spawner: The addressing-worker spawn seam.
    ///   - writer: The GitHub write seam for the conversation reply.
    ///   - gate: The autonomy gate for outward actions (issue #32).
    ///   - log: The per-comment activity log.
    ///   - selfLogin: Resolves the authenticated `gh` user's login for the
    ///     self-author loop guard.
    ///   - headBranchResolver: Resolves the PR head branch the gate-routed push
    ///     targets; `nil` makes the worker decline the push (ci-fix decline guard).
    public init(
        spawner: any WorkerSpawning,
        writer: any PullRequestWriting,
        gate: any OutwardActionGate,
        log: any ConversationCommentActivityLogging,
        selfLogin: @escaping @Sendable () async -> String?,
        headBranchResolver: @escaping @Sendable (PullRequestRef) async -> String? = { _ in nil }
    ) {
        self.worker = ConversationCommentWorker(
            spawner: spawner, writer: writer, gate: gate, log: log,
            headBranchResolver: headBranchResolver
        )
        self.selfLogin = selfLogin
    }

    /// The set of comment IDs handled so far. Exposed for tests and inspection.
    public var handledCommentIDs: Set<String> { handled }

    /// Forgets one PR's state for a dismissed shepherd (I2). Clears exactly that
    /// PR's handled / in-flight comment IDs and marks it dismissed so a late
    /// snapshot cannot re-trigger work. Mirrors ``CIFixReactor/cancel(for:)``.
    public func forget(for pullRequest: PullRequestRef) {
        dismissed.insert(pullRequest.id)
        let prCommentIDs = handledByPR.removeValue(forKey: pullRequest.id) ?? []
        handled.subtract(prCommentIDs)
        inFlight.subtract(prCommentIDs)
    }

    /// Re-arms a previously dismissed PR (on a fresh handoff).
    public func rearm(for pullRequest: PullRequestRef) {
        dismissed.remove(pullRequest.id)
    }

    /// Drives the reactor from a watcher's snapshot stream until it finishes.
    ///
    /// Each yielded ``ShepherdState`` is diffed via ``react(to:)``.
    ///
    /// - Parameter states: The shepherd's `AsyncStream` of state snapshots.
    public func observe(_ states: AsyncStream<ShepherdState>) async {
        for await state in states {
            await react(to: state)
        }
    }

    /// Processes a single shepherd snapshot, dispatching workers for any newly
    /// actionable, non-self-authored conversation comments.
    ///
    /// Exposed so tests can feed snapshots one at a time and assert the loop guard
    /// and idempotency without racing a live stream.
    ///
    /// - Parameter state: The latest shepherd state.
    public func react(to state: ShepherdState) async {
        // A dismissed PR is inert until a fresh handoff re-arms it (I2).
        guard !dismissed.contains(state.pullRequest.id) else { return }

        let policy = ShepherdAuthorPolicy(selfLogin: await resolveSelfLogin())

        // The timeline position of the current user's most recent reply, if any.
        // Anything at or before it has already been answered.
        let lastSelfReplyIndex = Self.lastSelfReplyIndex(
            in: state.conversationComments, policy: policy
        )

        let newComments = state.conversationComments.enumerated().filter { index, comment in
            Self.isActionable(comment, at: index, policy: policy, lastSelfReplyIndex: lastSelfReplyIndex)
                && !handled.contains(comment.id)
                && !inFlight.contains(comment.id)
        }.map(\.element)
        guard !newComments.isEmpty else { return }

        for comment in newComments {
            inFlight.insert(comment.id)
            let fullyHandled = await worker.handle(comment, in: state.pullRequest)
            inFlight.remove(comment.id)
            // A dismiss that landed mid-flight must win: do not record for a
            // now-dismissed PR (a re-handoff re-addresses it).
            if fullyHandled, !dismissed.contains(state.pullRequest.id) {
                handled.insert(comment.id)
                handledByPR[state.pullRequest.id, default: []].insert(comment.id)
            }
        }
    }

    /// Resolves the self-login once and caches the first non-empty result.
    private func resolveSelfLogin() async -> String? {
        if let cachedSelfLogin { return cachedSelfLogin }
        let login = await selfLogin()
        if let login, !login.isEmpty {
            cachedSelfLogin = login
        }
        return cachedSelfLogin
    }

    /// The index of the current user's **most recent** comment in the timeline,
    /// or `nil` if the user has not commented. Comments at or before this index
    /// are treated as already answered. Returns `nil` when the login is
    /// unresolved (the self rule cannot be applied).
    private static func lastSelfReplyIndex(
        in comments: [PRConversationComment], policy: ShepherdAuthorPolicy
    ) -> Int? {
        comments.lastIndex { policy.isSelf($0.author) }
    }

    /// A comment is actionable when it has a non-empty body, its author is
    /// actionable (not a bot, not the current user — the self-reply loop guard),
    /// **and** the current user has not already replied after it (already-answered
    /// guard).
    ///
    /// The self-author guard is the core correctness requirement: the shepherd's
    /// own reply is itself a conversation comment, so without skipping comments
    /// authored by the authenticated `gh` user the shepherd would reply to its
    /// own replies forever.
    private static func isActionable(
        _ comment: PRConversationComment,
        at index: Int,
        policy: ShepherdAuthorPolicy,
        lastSelfReplyIndex: Int?
    ) -> Bool {
        guard !comment.body.isEmpty else { return false }
        guard policy.isActionableAuthor(comment.author) else { return false }
        // Already answered: the user replied at a later timeline position.
        if let lastSelfReplyIndex, index <= lastSelfReplyIndex { return false }
        return true
    }
}
