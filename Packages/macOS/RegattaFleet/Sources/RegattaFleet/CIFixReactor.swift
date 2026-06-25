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

    /// Resolves the PR's **head branch** — the branch the gate-routed push targets
    /// (`git push origin HEAD:<branch>`). The reactor holds only a
    /// ``PullRequestRef`` (owner/repo/number), which does **not** carry the head
    /// branch, so the composition root injects this resolver (backed by the
    /// per-PR head-branch map recorded at handoff). When it returns `nil` the
    /// reactor cannot push to the correct branch and reports needs-attention rather
    /// than pushing the fix to a wrong branch.
    ///
    /// ## Why this exists (bug the integration test exposed)
    /// The fix loop previously built its worker spec with `branch: pullRequest.repo`
    /// — the **repository name**, not the PR head branch — so the gate-approved push
    /// went to a junk branch named after the repo (e.g. `HEAD:regatta`). The PR's
    /// real branch never received the fix, so its CI never went green and the loop
    /// gave up. Resolving the real head branch makes the push land on the PR.
    private let headBranchResolver: @Sendable (PullRequestRef) async -> String?

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

    /// PRs whose in-flight fix loop has been asked to cancel (via ``cancel(for:)``
    /// — the Fleet ✕ on a loop's worker, or a shepherd-dismiss cascade). The loop
    /// checks this each iteration and stops as ``CIFixOutcome/cancelled`` without
    /// spawning another worker. A cancelled PR is also cleared from ``failing`` and
    /// ``needsAttention`` so a stale red snapshot cannot immediately respawn it.
    private var cancelled: Set<String> = []

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
        headBranchResolver: @escaping @Sendable (PullRequestRef) async -> String? = { _ in nil },
        makeCondition: @escaping @Sendable (PullRequestRef) -> CIFixLoopCondition
    ) {
        self.spawner = spawner
        self.gate = gate
        self.maxIterations = maxIterations
        self.headBranchResolver = headBranchResolver
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
        maxIterations: Int = 5,
        headBranchResolver: @escaping @Sendable (PullRequestRef) async -> String? = { _ in nil }
    ) {
        self.spawner = spawner
        self.gate = gate
        self.maxIterations = maxIterations
        self.headBranchResolver = headBranchResolver
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
            // Re-arm: a non-failing snapshot lets a future failure trigger again,
            // including after a cancel — one cancel = one stop, but a later
            // green→red transition is a genuinely new situation.
            failing.remove(id)
            cancelled.remove(id)
            return nil
        }

        // Failing now. Only react on the transition into failing, and never while
        // a loop is already running for this PR. Once a PR is flagged
        // needs-attention, the reactor stops auto-pushing: no new fix loop spawns
        // until the human clears the flag (issue #35).
        let wasFailing = failing.contains(id)
        failing.insert(id)
        // Suppress auto-spawn while a PR is flagged needs-attention (issue #35) or
        // has been cancelled (one cancel = one stop): no new fix loop spawns for a
        // repeat red snapshot until a green snapshot re-arms it. The transition and
        // in-flight guards still apply.
        guard !wasFailing,
              !inFlight.contains(id),
              !needsAttention.contains(id),
              !cancelled.contains(id) else { return nil }

        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let outcome = await runFixLoop(for: state.pullRequest)
        switch outcome {
        case .needsAttention:
            // A loop that gives up (cap reached or push blocked) flags the PR so
            // the reactor stops auto-pushing until the human resolves it.
            needsAttention.insert(id)
        case .cancelled:
            // A user cancel / dismiss is a final stop, not a give-up: do NOT flag
            // needs-attention. Mark the PR cancelled so a stale red snapshot does
            // not immediately respawn; a green→red transition re-arms it.
            cancelled.insert(id)
        case .greenSuccess:
            break
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

    /// Cancels the in-flight fix loop for a PR — a final, idempotent stop.
    ///
    /// This is the reactor's half of the user-cancel / shepherd-dismiss contract:
    /// - The Fleet ✕ on a loop's worker cancels that worker *and* calls this so
    ///   the loop does not spawn a replacement (the "cancel respawns" bug).
    /// - A shepherd dismiss cascades here so the orphaned loop stops polling and
    ///   spawning (the "dismiss leaves loops running" bug).
    ///
    /// It sets a per-PR cancel flag the loop checks each iteration. The PR stays
    /// marked cancelled (suppressing auto re-spawn on a stale red snapshot) until a
    /// green snapshot re-arms it — "one cancel = one stop". Idempotent: cancelling
    /// a PR with no in-flight loop just records the flag (harmless).
    public func cancel(for pullRequest: PullRequestRef) {
        let id = pullRequest.id
        cancelled.insert(id)
        // A cancel is a final stop, not a give-up, so it clears any needs-attention
        // flag; it deliberately keeps `failing` set so a repeat red snapshot is not
        // seen as a fresh transition that would respawn a loop.
        needsAttention.remove(id)
    }

    /// Drives the spawn + fix loop for one PR and returns its outcome.
    ///
    /// Exposed so tests can run a loop directly without simulating a snapshot
    /// stream. Honours neither the transition guard nor the in-flight guard —
    /// those belong to ``ingest(_:)``.
    public func runFixLoop(for pullRequest: PullRequestRef) async -> CIFixOutcome {
        let id = pullRequest.id
        // Resolve the PR's real head branch so the gate-routed push targets the PR
        // (`git push origin HEAD:<headBranch>`). When the head branch is unknown
        // (no handoff recorded it, or a store miss) the resolver returns `nil`: the
        // loop must NOT fall back to pushing `HEAD:<repoName>` — that lands the fix
        // on a junk branch named after the repo, so the PR's CI never goes green and
        // the loop spins to the cap (the wrong-push-branch bug the e2e test exposed,
        // and that the production composition root assumes is handled here). The spec
        // carries an empty branch in that case and the push is declined below.
        let headBranch = await headBranchResolver(pullRequest)
        let spec = CIFixWorkerSpec(pullRequest: pullRequest, branch: headBranch ?? "")
        let worker = await spawner.spawn(spec)
        let condition = makeCondition(pullRequest)

        var iteration = 0
        while true {
            // A cancel requested before this iteration starts is a final stop —
            // never spawn the next worker. This closes the window where a dismiss
            // / ✕ lands between iterations.
            if cancelled.contains(id) {
                return .cancelled
            }

            let attempt = await worker.attemptFix()

            // A cancelled/killed worker (user ✕, dismiss cascade, SIGTERM/SIGKILL)
            // stops the loop. This is the core fix: a cancel is "stop", never
            // "iteration finished, not green → advance + respawn".
            if attempt == .cancelled || cancelled.contains(id) {
                return .cancelled
            }

            let producedFix = attempt == .produced
            if producedFix {
                // The worker produced a fix, but we never resolved the PR's real head
                // branch — pushing now would target a wrong branch. Decline and flag
                // for the human instead of corrupting the PR with a junk-branch push.
                guard !spec.branch.isEmpty else {
                    return .needsAttention(
                        reason: "Couldn't make CI green — a fix is ready but the PR's head branch couldn't be resolved, so the push was held to avoid pushing to the wrong branch"
                    )
                }
                // The worker committed locally (it is prompted to commit, not push).
                // Route the *push* of those commits through the autonomy gate so a
                // staged PR holds it for approval and an auto PR pushes immediately.
                let verdict = await gate.authorize(
                    .pushFix(pullRequest: pullRequest, branch: spec.branch),
                    for: pullRequest
                )
                if verdict == .denied {
                    return .needsAttention(
                        reason: "Couldn't make CI green — fix is staged but the push was blocked by the autonomy gate"
                    )
                }
            }

            // Re-poll checks (this also refreshes ``isGreen``). A green result wins
            // even when the worker produced nothing this iteration (e.g. an external
            // push turned CI green) — the loop's job is done.
            let decision = await condition.evaluate(iteration: iteration)
            if decision == .stop {
                if await condition.isGreen {
                    return .greenSuccess
                }
                // Cap reached while still red. Name the still-failing checks and the
                // number of attempts so the human knows it gave up (vs is still
                // working).
                let checks = await condition.lastSummary
                return .needsAttention(
                    reason: Self.capReason(
                        attempts: maxIterations,
                        failing: checks?.failedCheckNames ?? []
                    )
                )
            }

            // No-progress guard: the worker produced no new commits and CI is not
            // green. Continuing would respawn an identical no-op worker every
            // iteration up to the cap (the "runs, does nothing, exits Done" loop the
            // user saw). Stop now and flag the PR for human attention instead.
            if !producedFix {
                let checks = await condition.lastSummary
                return .needsAttention(
                    reason: Self.noProgressReason(failing: checks?.failedCheckNames ?? [])
                )
            }

            iteration += 1
        }
    }

    // MARK: - Reason wording

    /// Builds the "gave up at the cap" needs-attention reason, naming the
    /// still-failing checks and the number of attempts. Distinguishes the cap stop
    /// from the no-progress stop so the user can tell the worker gave up.
    static func capReason(attempts: Int, failing: [String]) -> String {
        let suffix = checksSuffix(failing)
        return "Couldn't make CI green — gave up after \(attempts) attempts\(suffix)"
    }

    /// Builds the "no fix found" needs-attention reason, naming the still-failing
    /// checks. Distinguishes the no-progress stop ("nothing the agent could fix")
    /// from the cap stop.
    static func noProgressReason(failing: [String]) -> String {
        if failing.isEmpty {
            return "Couldn't make CI green — no code-level fix found"
        }
        return "Couldn't make CI green — no code-level fix found for: \(failing.joined(separator: ", "))"
    }

    /// The trailing "still failing: a, b" clause shared by the reasons, or an
    /// empty string when no failing check names are known.
    private static func checksSuffix(_ failing: [String]) -> String {
        guard !failing.isEmpty else { return "" }
        return "; still failing: \(failing.joined(separator: ", "))"
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
