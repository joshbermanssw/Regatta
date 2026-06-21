public import RegattaGitHub

/// An immutable snapshot of a PR shepherd watcher's current state.
///
/// ``ShepherdWatcher`` publishes a new `ShepherdState` on its `AsyncStream`
/// after every poll. The value is fully `Sendable` so it crosses the actor
/// boundary into the `@MainActor` view layer and feeds list rows directly,
/// honouring the snapshot-boundary rule (no store reference escapes into a
/// `ForEach`).
///
/// `ShepherdState` also conforms to ``FleetEntry`` so it can appear in the Fleet
/// section as a persistent ``FleetEntryKind/shepherd``, distinct from ephemeral
/// workers.
public struct ShepherdState: Sendable, Equatable, Identifiable, FleetEntry {
    /// The pull request this shepherd watches; also its Fleet identity.
    public let pullRequest: PullRequestRef

    /// The watcher's polling lifecycle phase.
    public let phase: ShepherdPollPhase

    /// The rolled-up CI checks from the most recent successful poll.
    /// Empty until the first poll completes.
    public let checks: PRCheckSummary

    /// The review threads from the most recent successful poll.
    /// Empty until the first poll completes.
    public let reviewThreads: [ReviewThread]

    /// The per-PR autonomy policy gating outward actions (push/reply/resolve).
    ///
    /// Defaults to ``AutonomyMode/staged`` for new handoffs (#32 safety policy).
    /// The view layer reads this to render the mode toggle; flipping it routes
    /// through the ``Fleet`` to the shared ``AutonomyGate``.
    public let autonomyMode: AutonomyMode

    /// A human-resolution flag set when the shepherd gave up automating a PR —
    /// e.g. the ci-fix loop hit its cap without CI going green (issue #35). While
    /// set, the shepherd stops auto-pushing fixes and the card surfaces a "needs
    /// attention" banner with this reason. `nil` when the shepherd is operating
    /// normally. Additive so #34's persistence layer can store it without
    /// reshaping the state.
    public let needsAttention: String?

    /// Stable Fleet identity, derived from the PR reference.
    public var id: String { pullRequest.id }

    /// A PR shepherd is always a persistent watcher.
    public var kind: FleetEntryKind { .shepherd }

    /// The row label, e.g. `"cmux#28"`.
    public var title: String { "\(pullRequest.repo)#\(pullRequest.number)" }

    /// The number of review threads that are open (neither resolved nor outdated).
    public var unresolvedThreadCount: Int {
        reviewThreads.filter { !$0.isResolved && !$0.isOutdated }.count
    }

    /// Creates a shepherd state snapshot.
    ///
    /// - Parameters:
    ///   - pullRequest: The watched pull request.
    ///   - phase: The polling lifecycle phase.
    ///   - checks: The latest CI check rollup. Defaults to empty.
    ///   - reviewThreads: The latest review threads. Defaults to empty.
    ///   - autonomyMode: The per-PR autonomy policy. Defaults to
    ///     ``AutonomyMode/staged`` (the #32 safety default for new handoffs).
    ///   - needsAttention: The human-resolution reason, or `nil` (issue #35).
    public init(
        pullRequest: PullRequestRef,
        phase: ShepherdPollPhase,
        checks: PRCheckSummary = PRCheckSummary(checks: []),
        reviewThreads: [ReviewThread] = [],
        autonomyMode: AutonomyMode = .staged,
        needsAttention: String? = nil
    ) {
        self.pullRequest = pullRequest
        self.phase = phase
        self.checks = checks
        self.reviewThreads = reviewThreads
        self.autonomyMode = autonomyMode
        self.needsAttention = needsAttention
    }
}
