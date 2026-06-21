public import RegattaGitHub

/// The "until checks green" exit condition for the CI fix loop.
///
/// Each evaluation re-polls the pull request's CI checks through the injected
/// ``PullRequestPolling`` (the #28 polling layer) and decides whether the loop
/// should keep fixing or stop:
///
/// - **green** (every check completed `SUCCESS`) → ``LoopDecision/stop``,
/// - **still red or pending** → ``LoopDecision/continueLooping``,
/// - **cap reached** (`iteration >= maxIterations`) → ``LoopDecision/stop``.
///
/// The condition only *decides*; ``CIFixReactor`` distinguishes "stopped green"
/// from "stopped at cap" by re-reading ``lastSummary`` after the loop ends.
///
/// A poll failure is treated as not-green: the loop continues (up to the cap) so
/// a transient `gh` error does not falsely report success. The last summary is
/// left unchanged on a failed poll.
///
/// ## Wiring note (#19)
/// This is the local stand-in for a `RegattaLoopCondition`. When the loop engine
/// (#19) merges, this type conforms to the engine's condition protocol unchanged
/// — the per-iteration async decision shape already matches.
public actor CIFixLoopCondition: LoopConditionEvaluating {
    private let pullRequest: PullRequestRef
    private let poller: any PullRequestPolling
    private let maxIterations: Int

    private var summary: PRCheckSummary?

    /// Creates the exit condition.
    ///
    /// - Parameters:
    ///   - pullRequest: The PR whose checks gate the loop.
    ///   - poller: The polling seam used to re-read checks each iteration.
    ///   - maxIterations: The hard cap on fix iterations. The loop stops once an
    ///     evaluation is asked about an iteration at or beyond this index, even
    ///     if checks are still red.
    public init(
        pullRequest: PullRequestRef,
        poller: any PullRequestPolling,
        maxIterations: Int
    ) {
        self.pullRequest = pullRequest
        self.poller = poller
        self.maxIterations = maxIterations
    }

    /// The most recent check summary fetched by ``evaluate(iteration:)``, or
    /// `nil` before the first successful poll. ``CIFixReactor`` reads this to
    /// classify why the loop stopped.
    public var lastSummary: PRCheckSummary? { summary }

    /// Whether the last polled summary shows every check green.
    public var isGreen: Bool { summary?.allSucceeded == true }

    public func evaluate(iteration: Int) async -> LoopDecision {
        if iteration >= maxIterations {
            return .stop
        }
        do {
            let checks = try await poller.fetchChecks(
                owner: pullRequest.owner,
                repo: pullRequest.repo,
                prNumber: pullRequest.number
            )
            let next = PRCheckSummary(checks: checks)
            summary = next
            return next.allSucceeded ? .stop : .continueLooping
        } catch {
            // Treat a transient poll failure as not-green; keep last summary.
            return .continueLooping
        }
    }
}
