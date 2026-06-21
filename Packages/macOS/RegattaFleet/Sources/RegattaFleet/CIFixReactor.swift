public import RegattaGitHub
import Foundation

/// Reacts to a shepherd's CI checks turning red by spawning a `ci-fix` worker and
/// driving a "fix until green" loop, then records the terminal ``CIFixOutcome``.
///
/// ``CIFixReactor`` is the issue-#30 glue between three not-yet-merged seams:
/// - it observes ``ShepherdState`` transitions to failing checks,
/// - spawns a `ci-fix` worker via ``WorkerSpawning`` (#14/#16),
/// - loops toward green using ``CIFixLoopCondition`` + ``LoopConditionEvaluating``
///   (#19), re-polling checks through the #28 polling layer,
/// - and routes every push through ``OutwardActionGate`` (#32).
///
/// ## Failure-edge transition detection
/// The reactor only reacts when checks *transition* into a failing state — going
/// from "no failure observed" to ``PRCheckSummary/anyFailed``. It does not
/// re-trigger on every subsequent red snapshot for the same failure, so a single
/// CI failure spawns a single fix loop. After a loop ends, a fresh red→…→red
/// transition is required to react again (the reactor re-arms once it observes a
/// non-failing snapshot, e.g. once a fix turns checks green or pending).
///
/// ## The loop
/// Each iteration: ask the worker to attempt a fix; if it produced changes,
/// authorize a ``OutwardAction/pushFix`` through the gate; then evaluate the exit
/// condition (which re-polls checks). The loop stops when the condition says so —
/// either checks went green or the iteration cap was hit. The reactor then
/// classifies the outcome:
/// - checks green → ``CIFixOutcome/greenSuccess``,
/// - push denied by the gate → ``CIFixOutcome/needsAttention(reason:)``,
/// - cap reached while still red → ``CIFixOutcome/needsAttention(reason:)``.
///
/// ## Concurrency
/// `actor` — all mutable state (the per-PR re-arm flags and the loop guard) is
/// isolated. Outcomes are published on an `AsyncStream` so the Fleet/UI layer can
/// surface success or a `needs attention` flag without reaching into the actor.
public actor CIFixReactor {
    private let spawner: any WorkerSpawning
    private let gate: any OutwardActionGate
    private let maxIterations: Int
    private let makeCondition: @Sendable (PullRequestRef) -> CIFixLoopCondition

    /// PRs that have an in-flight fix loop, so a second red snapshot does not
    /// spawn a duplicate loop while one is running.
    private var inFlight: Set<String> = []

    /// PRs currently observed as failing, used for edge (transition) detection.
    private var failing: Set<String> = []

    /// PRs the reactor has given up auto-fixing — the fix loop hit its cap (or was
    /// blocked) and flipped the PR to "needs attention" (issue #35). While a PR is
    /// in this set the reactor stops auto-pushing: it will not spawn another fix
    /// loop for a repeat failure until the human clears the flag via
    /// ``clearNeedsAttention(for:)``. This is the "CI never green → stop
    /// auto-pushing" guarantee.
    private var needsAttention: Set<String> = []

    private var continuations: [UUID: AsyncStream<CIFixOutcome>.Continuation] = [:]

    /// Creates a reactor with an explicit loop-condition factory.
    ///
    /// - Parameters:
    ///   - spawner: The `ci-fix` worker spawner seam (#14/#16).
    ///   - gate: The autonomy gate every push is routed through (#32).
    ///   - maxIterations: The fix-loop cap. Defaults to 5.
    ///   - makeCondition: Builds the "until green" condition for a PR. Injected so
    ///     tests supply a condition backed by a fake poller.
    public init(
        spawner: any WorkerSpawning,
        gate: any OutwardActionGate,
        maxIterations: Int = 5,
        makeCondition: @escaping @Sendable (PullRequestRef) -> CIFixLoopCondition
    ) {
        self.spawner = spawner
        self.gate = gate
        self.maxIterations = maxIterations
        self.makeCondition = makeCondition
    }

    /// Creates a reactor whose conditions share one ``PullRequestPolling``.
    ///
    /// - Parameters:
    ///   - spawner: The `ci-fix` worker spawner seam (#14/#16).
    ///   - gate: The autonomy gate every push is routed through (#32).
    ///   - poller: The shared polling seam the conditions re-poll checks with.
    ///   - maxIterations: The fix-loop cap. Defaults to 5.
    public init(
        spawner: any WorkerSpawning,
        gate: any OutwardActionGate,
        poller: any PullRequestPolling,
        maxIterations: Int = 5
    ) {
        self.spawner = spawner
        self.gate = gate
        self.maxIterations = maxIterations
        self.makeCondition = { ref in
            CIFixLoopCondition(pullRequest: ref, poller: poller, maxIterations: maxIterations)
        }
    }

    /// An `AsyncStream` of terminal fix-loop outcomes, one per completed loop.
    public func outcomes() -> AsyncStream<CIFixOutcome> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token) }
            }
        }
    }

    /// Feeds one shepherd snapshot to the reactor.
    ///
    /// When the snapshot's checks transition into a failing state (and no loop is
    /// already in flight for that PR), the reactor spawns a `ci-fix` worker and
    /// runs the fix loop, returning its terminal outcome. A non-failing or
    /// repeat-failing snapshot returns `nil` without spawning.
    ///
    /// - Parameter state: The latest shepherd snapshot.
    /// - Returns: The ``CIFixOutcome`` when this snapshot triggered (and ran) a
    ///   loop, or `nil` when it did not trigger one.
    @discardableResult
    public func ingest(_ state: ShepherdState) async -> CIFixOutcome? {
        let id = state.pullRequest.id
        let isFailingNow = state.checks.anyFailed

        guard isFailingNow else {
            // Re-arm: a non-failing snapshot lets a future failure trigger again.
            failing.remove(id)
            return nil
        }

        // Failing now. Only react on the transition into failing, and never while
        // a loop is already running for this PR. Once a PR is flagged
        // needs-attention, the reactor stops auto-pushing: no new fix loop spawns
        // until the human clears the flag (issue #35).
        let wasFailing = failing.contains(id)
        failing.insert(id)
        // A PR flagged needs-attention has stopped auto-pushing: it will not spawn
        // another fix loop for a repeat failure until the human clears the flag
        // (issue #35 — "CI never green → stop auto-pushing"). The transition and
        // in-flight guards still apply.
        guard !wasFailing, !inFlight.contains(id), !needsAttention.contains(id) else { return nil }

        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let outcome = await runFixLoop(for: state.pullRequest)
        // A loop that gives up (cap reached or push blocked) flags the PR so the
        // reactor stops auto-pushing until the human resolves it.
        if case .needsAttention = outcome {
            needsAttention.insert(id)
        }
        publish(outcome)
        return outcome
    }

    /// Whether the reactor has flagged this PR as needing human attention and has
    /// therefore stopped auto-pushing fixes for it (issue #35).
    public func isNeedingAttention(_ pullRequest: PullRequestRef) -> Bool {
        needsAttention.contains(pullRequest.id)
    }

    /// Clears the needs-attention flag for a PR so the reactor will react to a
    /// future CI failure again. Called when the human has resolved the situation.
    public func clearNeedsAttention(for pullRequest: PullRequestRef) {
        needsAttention.remove(pullRequest.id)
    }

    /// Drives the spawn + fix loop for one PR and returns its outcome.
    ///
    /// Exposed so tests can run a loop directly without simulating a snapshot
    /// stream. Honours neither the transition guard nor the in-flight guard —
    /// those belong to ``ingest(_:)``.
    public func runFixLoop(for pullRequest: PullRequestRef) async -> CIFixOutcome {
        let spec = CIFixWorkerSpec(pullRequest: pullRequest, branch: pullRequest.repo)
        let worker = await spawner.spawn(spec)
        let condition = makeCondition(pullRequest)

        var iteration = 0
        while true {
            let producedFix = await worker.attemptFix()
            if producedFix {
                let verdict = await gate.authorize(
                    .pushFix(pullRequest: pullRequest, branch: spec.branch),
                    for: pullRequest
                )
                if verdict == .denied {
                    return .needsAttention(reason: "Push blocked by autonomy gate")
                }
            }

            let decision = await condition.evaluate(iteration: iteration)
            if decision == .stop {
                if await condition.isGreen {
                    return .greenSuccess
                }
                return .needsAttention(
                    reason: "CI still failing after \(maxIterations) fix attempts"
                )
            }
            iteration += 1
        }
    }

    // MARK: - Private

    private func publish(_ outcome: CIFixOutcome) {
        for continuation in continuations.values {
            continuation.yield(outcome)
        }
    }

    private func removeContinuation(_ token: UUID) {
        continuations[token] = nil
    }
}
