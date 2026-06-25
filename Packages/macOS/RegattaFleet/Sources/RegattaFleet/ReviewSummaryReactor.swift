public import RegattaGitHub
import Foundation

/// The reactive layer that turns a reviewer's **submitted review summary** into
/// addressing work — acting on the note a reviewer leaves when they Approve,
/// Request changes, or Comment, not just on line-comment threads and
/// conversation comments.
///
/// Real motivating case: a PR approved with a summary comment produces neither a
/// review thread nor a conversation comment, so nothing else reacts to it. A
/// `ReviewSummaryReactor` observes a shepherd's successive ``ShepherdState``
/// snapshots and, each time a poll reveals an actionable review it has not yet
/// handled, dispatches a ``ReviewSummaryWorker`` to address the review body. The
/// worker decides what to do; a pure approval reports "nothing done" and posts
/// no reply.
///
/// ## Actionable-review policy
/// A review is **actionable** when:
/// - it passes the shared author skip rules (``ShepherdAuthorPolicy``): NOT
///   authored by the current `gh` user (self — the shepherd's own review), and
///   NOT a bot (`[bot]`); AND
/// - it is not already handled (handled-id set keyed by review id) or in flight;
///   AND
/// - it is not already answered: the current user submitted a **later** review,
///   which supersedes anything at or before it; AND
/// - its state makes it actionable:
///   - ``PRReview/State/changesRequested`` is **always** actionable (the
///     reviewer is blocking the PR — even an empty body means "address my
///     changes"); whereas
///   - ``PRReview/State/commented`` and ``PRReview/State/approved`` are
///     actionable only when the body is **substantive** — a non-empty body that
///     is more than a trivial acknowledgement like "LGTM" / "ship it".
///   - ``PRReview/State/dismissed`` and ``PRReview/State/other`` are never
///     actionable.
///
/// ## Idempotency
/// Each review id is handled **once**. The reactor records a review id as handled
/// only when its worker reports the review was *fully* handled; a review whose
/// worker was suppressed by the autonomy gate or that failed is left unrecorded
/// so the next poll retries it. In-flight ids are also tracked so two rapid polls
/// cannot spawn two workers for the same review.
///
/// ## Concurrency
/// `actor` — the handled / in-flight id sets and the cached login are
/// actor-isolated. ``observe(_:)`` drives the reactor from a watcher's
/// `AsyncStream`; ``react(to:)`` processes one snapshot and is exposed so tests
/// can drive exactly one diff deterministically.
public actor ReviewSummaryReactor {
    private let worker: ReviewSummaryWorker

    /// Resolves the authenticated `gh` user's login. Returns `nil` when the
    /// lookup fails; the reactor then skips bots but cannot apply the self-author
    /// rule for that poll (and retries the login on the next poll).
    private let selfLogin: @Sendable () async -> String?

    /// The cached self-login, resolved on first successful lookup.
    private var cachedSelfLogin: String?

    /// Review IDs that have been fully handled; never re-dispatched.
    private var handled: Set<String> = []
    /// Review IDs with a worker currently in flight; guards against a second poll
    /// dispatching a duplicate before the first finishes.
    private var inFlight: Set<String> = []

    /// Handled review IDs grouped by PR id, so ``forget(for:)`` clears exactly one
    /// PR's set without disturbing other PRs (the reactor is shared app-wide).
    private var handledByPR: [String: Set<String>] = [:]

    /// PRs whose shepherd was dismissed; their snapshots are ignored until a fresh
    /// handoff re-arms them (``rearm(for:)``), so a late snapshot cannot re-trigger
    /// dismissed work (I2).
    private var dismissed: Set<String> = []

    /// Trivial acknowledgement bodies that are **not** substantive enough to act
    /// on for a non-blocking review (compared case-insensitively after trimming
    /// and stripping trailing punctuation).
    private static let trivialBodies: Set<String> = [
        "", "lgtm", "looks good", "looks good to me", "ship it", "+1", "👍",
        "nice", "great", "thanks", "approved", "ok", "okay",
    ]

    /// Creates a reactor that dispatches the given worker.
    ///
    /// - Parameters:
    ///   - worker: The per-review worker used to address each new review.
    ///   - selfLogin: Resolves the authenticated `gh` user's login for the
    ///     self-author / already-answered skip rules.
    public init(
        worker: ReviewSummaryWorker,
        selfLogin: @escaping @Sendable () async -> String?
    ) {
        self.worker = worker
        self.selfLogin = selfLogin
    }

    /// Convenience initializer that assembles the worker from its seams.
    ///
    /// - Parameters:
    ///   - spawner: The addressing-worker spawn seam.
    ///   - writer: The GitHub write seam for the reply.
    ///   - gate: The autonomy gate for outward actions (issue #32).
    ///   - log: The per-review activity log.
    ///   - selfLogin: Resolves the authenticated `gh` user's login for the
    ///     self-author / already-answered skip rules.
    ///   - headBranchResolver: Resolves the PR head branch the gate-routed push
    ///     targets; `nil` makes the worker decline the push (ci-fix decline guard).
    public init(
        spawner: any WorkerSpawning,
        writer: any PullRequestWriting,
        gate: any OutwardActionGate,
        log: any ReviewSummaryActivityLogging,
        selfLogin: @escaping @Sendable () async -> String?,
        headBranchResolver: @escaping @Sendable (PullRequestRef) async -> String? = { _ in nil }
    ) {
        self.worker = ReviewSummaryWorker(
            spawner: spawner, writer: writer, gate: gate, log: log,
            headBranchResolver: headBranchResolver
        )
        self.selfLogin = selfLogin
    }

    /// The set of review IDs handled so far. Exposed for tests and inspection.
    public var handledReviewIDs: Set<String> { handled }

    /// Forgets one PR's state for a dismissed shepherd (I2). Clears exactly that
    /// PR's handled / in-flight review IDs and marks it dismissed so a late
    /// snapshot cannot re-trigger work. Mirrors ``CIFixReactor/cancel(for:)``.
    public func forget(for pullRequest: PullRequestRef) {
        dismissed.insert(pullRequest.id)
        let prReviewIDs = handledByPR.removeValue(forKey: pullRequest.id) ?? []
        handled.subtract(prReviewIDs)
        inFlight.subtract(prReviewIDs)
    }

    /// Re-arms a previously dismissed PR (on a fresh handoff).
    public func rearm(for pullRequest: PullRequestRef) {
        dismissed.remove(pullRequest.id)
    }

    /// Drives the reactor from a watcher's snapshot stream until it finishes.
    ///
    /// - Parameter states: The shepherd's `AsyncStream` of state snapshots.
    public func observe(_ states: AsyncStream<ShepherdState>) async {
        for await state in states {
            await react(to: state)
        }
    }

    /// Processes a single shepherd snapshot, dispatching workers for any newly
    /// actionable, non-self-authored reviews.
    ///
    /// Exposed so tests can feed snapshots one at a time and assert the skip rules
    /// and idempotency without racing a live stream.
    ///
    /// - Parameter state: The latest shepherd state.
    public func react(to state: ShepherdState) async {
        // A dismissed PR is inert until a fresh handoff re-arms it (I2).
        guard !dismissed.contains(state.pullRequest.id) else { return }

        let policy = ShepherdAuthorPolicy(selfLogin: await resolveSelfLogin())

        // The timeline position of the current user's most recent review, if any.
        // Anything at or before it has been superseded ("already answered").
        let lastSelfReviewIndex = Self.lastSelfReviewIndex(in: state.reviews, policy: policy)

        let newReviews = state.reviews.enumerated().filter { index, review in
            Self.isActionable(review, at: index, policy: policy, lastSelfReviewIndex: lastSelfReviewIndex)
                && !handled.contains(review.id)
                && !inFlight.contains(review.id)
        }.map(\.element)
        guard !newReviews.isEmpty else { return }

        for review in newReviews {
            inFlight.insert(review.id)
            let fullyHandled = await worker.handle(review, in: state.pullRequest)
            inFlight.remove(review.id)
            // A dismiss that landed mid-flight must win: do not record for a
            // now-dismissed PR (a re-handoff re-addresses it).
            if fullyHandled, !dismissed.contains(state.pullRequest.id) {
                handled.insert(review.id)
                handledByPR[state.pullRequest.id, default: []].insert(review.id)
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

    /// The index of the current user's **most recent** review in the timeline, or
    /// `nil` if the user has not reviewed. Reviews at or before this index are
    /// treated as already answered. Returns `nil` when the login is unresolved.
    private static func lastSelfReviewIndex(
        in reviews: [PRReview], policy: ShepherdAuthorPolicy
    ) -> Int? {
        reviews.lastIndex { policy.isSelf($0.author) }
    }

    /// A review is actionable when its author is actionable (not a bot, not the
    /// current user), it has not been superseded by a later self review, and its
    /// state + body make it worth acting on.
    static func isActionable(
        _ review: PRReview,
        at index: Int,
        policy: ShepherdAuthorPolicy,
        lastSelfReviewIndex: Int?
    ) -> Bool {
        guard policy.isActionableAuthor(review.author) else { return false }
        // Already answered / superseded: the user reviewed at a later position.
        if let lastSelfReviewIndex, index <= lastSelfReviewIndex { return false }

        switch review.state {
        case .changesRequested:
            // A blocking review is always actionable, even with an empty body —
            // "address my requested changes".
            return true
        case .commented, .approved:
            // Non-blocking: only worth acting on with a substantive note.
            return isSubstantive(review.body)
        case .dismissed, .other:
            return false
        }
    }

    /// Whether a review body is substantive enough to act on (for non-blocking
    /// reviews): non-empty and more than a trivial acknowledgement like "LGTM".
    static func isSubstantive(_ body: String) -> Bool {
        let normalized = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return false }
        return !trivialBodies.contains(normalized)
    }
}
