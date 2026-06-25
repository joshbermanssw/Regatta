public import RegattaGitHub

/// The reactive layer that turns new reviewer comments into addressing work.
///
/// A `ReviewThreadReactor` observes a shepherd's successive ``ShepherdState``
/// snapshots and, each time a poll reveals a review thread it has not yet
/// handled, dispatches a ``ReviewThreadWorker`` to address that thread — push a
/// code change and/or post a reply, then resolve it (issue #31).
///
/// ## New-comment detection
/// "New comment" is detected by diffing successive `reviewThreads` polls against
/// the set of thread IDs already handled. A thread is **actionable** when it is
/// open (not resolved, not outdated), has at least one comment, and its last
/// (most recent) comment is authored by someone the shepherd should act on.
/// Resolved and outdated threads are ignored.
///
/// ## Author skip rules (loop & noise prevention)
/// The thread's **last** comment is the actionable one; the reactor skips a
/// thread when that comment is authored by:
/// - a **bot** (login ending in `[bot]`, e.g. `vercel[bot]`) — automated
///   comments are never actionable; or
/// - the **current `gh` user** — that means either the user's own remark or the
///   shepherd's own reply, so the thread is *already answered* and must not be
///   re-actioned (the self-reply loop guard).
///
/// The authenticated login is resolved once via the injected ``selfLogin``
/// provider and cached. If it cannot be resolved the reactor still skips bots
/// and resolved/outdated threads; it conservatively cannot apply the self-author
/// rule, and relies on the handled-id set so it never re-spawns endlessly.
///
/// ## Idempotency
/// Each thread ID is handled **once**. The reactor records a thread ID as
/// handled only when its worker reports the thread was *fully* handled; a thread
/// whose worker was suppressed by the autonomy gate (issue #32) or that failed
/// is left unrecorded so the next poll retries it. In-flight threads are also
/// tracked so two rapid polls cannot spawn two workers for the same thread.
///
/// ## Concurrency
/// `actor` — the handled / in-flight ID sets and the cached login are
/// actor-isolated. ``observe(_:)`` drives the reactor from a watcher's
/// `AsyncStream`; ``react(to:)`` processes one snapshot and is exposed so tests
/// can drive exactly one diff deterministically.
public actor ReviewThreadReactor {
    private let worker: ReviewThreadWorker

    /// Resolves the authenticated `gh` user's login. Returns `nil` when the
    /// lookup fails; the reactor then skips bots and resolved threads but cannot
    /// apply the self-author rule for that poll (and retries the login next poll).
    private let selfLogin: @Sendable () async -> String?

    /// The cached self-login, resolved on first successful lookup.
    private var cachedSelfLogin: String?

    /// Thread IDs that have been fully handled; never re-dispatched.
    private var handled: Set<String> = []
    /// Thread IDs with a worker currently in flight; guards against a second
    /// poll dispatching a duplicate before the first finishes.
    private var inFlight: Set<String> = []

    /// Handled thread IDs grouped by PR id, so ``forget(for:)`` can clear exactly
    /// one PR's handled set without disturbing other PRs (the reactor is shared
    /// app-wide across every shepherd). Thread IDs are globally unique, but a
    /// dismiss must only forget the dismissed PR's IDs.
    private var handledByPR: [String: Set<String>] = [:]

    /// PRs whose shepherd was dismissed (via ``forget(for:)``). A dismissed PR's
    /// snapshots are ignored so a late snapshot — one already queued when the
    /// dismiss landed — cannot re-trigger work for a PR the user dismissed.
    /// Cleared by ``rearm(for:)`` on a fresh handoff.
    private var dismissed: Set<String> = []

    /// Creates a reactor that dispatches the given worker.
    ///
    /// - Parameters:
    ///   - worker: The per-thread worker used to address each new thread.
    ///   - selfLogin: Resolves the authenticated `gh` user's login for the
    ///     self-author / already-answered skip rules.
    public init(
        worker: ReviewThreadWorker,
        selfLogin: @escaping @Sendable () async -> String?
    ) {
        self.worker = worker
        self.selfLogin = selfLogin
    }

    /// Convenience initializer that assembles the worker from its seams.
    ///
    /// - Parameters:
    ///   - spawner: The addressing-worker spawn seam (issue #16).
    ///   - writer: The GitHub write seam for replies/resolves.
    ///   - gate: The autonomy gate for outward actions (issue #32).
    ///   - log: The per-thread activity log.
    ///   - selfLogin: Resolves the authenticated `gh` user's login for the
    ///     self-author / already-answered skip rules.
    ///   - headBranchResolver: Resolves the PR head branch the gate-routed push
    ///     targets; `nil` makes the worker decline the push (ci-fix decline guard).
    public init(
        spawner: any WorkerSpawning,
        writer: any PullRequestWriting,
        gate: any OutwardActionGate,
        log: any ReviewThreadActivityLogging,
        selfLogin: @escaping @Sendable () async -> String?,
        headBranchResolver: @escaping @Sendable (PullRequestRef) async -> String? = { _ in nil }
    ) {
        self.worker = ReviewThreadWorker(
            spawner: spawner, writer: writer, gate: gate, log: log,
            headBranchResolver: headBranchResolver
        )
        self.selfLogin = selfLogin
    }

    /// The set of thread IDs handled so far. Exposed for tests and inspection.
    public var handledThreadIDs: Set<String> { handled }

    /// Forgets one PR's state for a dismissed shepherd (I2).
    ///
    /// Clears exactly the dismissed PR's handled / in-flight thread IDs (leaving
    /// other PRs' state intact, since the reactor is shared app-wide) and marks the
    /// PR **dismissed**, so a late snapshot already queued when the dismiss landed
    /// cannot re-trigger work for it. Called by the shepherd-dismiss cascade,
    /// mirroring ``CIFixReactor/cancel(for:)``. A later ``rearm(for:)`` (on a fresh
    /// handoff) clears the dismissed-guard.
    public func forget(for pullRequest: PullRequestRef) {
        dismissed.insert(pullRequest.id)
        let prThreadIDs = handledByPR.removeValue(forKey: pullRequest.id) ?? []
        handled.subtract(prThreadIDs)
        inFlight.subtract(prThreadIDs)
    }

    /// Re-arms a previously dismissed PR (on a fresh handoff) so its snapshots are
    /// processed again.
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
    /// actionable threads.
    ///
    /// Exposed so tests can feed snapshots one at a time and assert idempotency
    /// without racing a live stream.
    ///
    /// - Parameter state: The latest shepherd state.
    public func react(to state: ShepherdState) async {
        // A dismissed PR is inert until a fresh handoff re-arms it (``rearm(for:)``),
        // so a late snapshot cannot re-trigger work the user dismissed (I2).
        guard !dismissed.contains(state.pullRequest.id) else { return }

        let policy = ShepherdAuthorPolicy(selfLogin: await resolveSelfLogin())

        let newThreads = state.reviewThreads.filter { thread in
            Self.isActionable(thread, policy: policy)
                && !handled.contains(thread.id)
                && !inFlight.contains(thread.id)
        }
        guard !newThreads.isEmpty else { return }

        for thread in newThreads {
            inFlight.insert(thread.id)
            let fullyHandled = await worker.handle(thread, in: state.pullRequest)
            inFlight.remove(thread.id)
            // A dismiss that landed while the worker ran must win: do not record the
            // thread as handled for a now-dismissed PR (a re-handoff re-addresses it).
            if fullyHandled, !dismissed.contains(state.pullRequest.id) {
                handled.insert(thread.id)
                handledByPR[state.pullRequest.id, default: []].insert(thread.id)
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

    /// A thread is actionable when it is open, carries at least one comment, and
    /// its **last** comment's author is actionable (not a bot, not the current
    /// user — the latter covering both the user's own thread and an
    /// already-answered thread).
    private static func isActionable(_ thread: ReviewThread, policy: ShepherdAuthorPolicy) -> Bool {
        guard !thread.isResolved, !thread.isOutdated, let last = thread.comments.last else {
            return false
        }
        return policy.isActionableAuthor(last.author)
    }
}
