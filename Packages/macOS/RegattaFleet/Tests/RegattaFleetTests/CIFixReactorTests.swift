import Testing
import RegattaGitHub
@testable import RegattaFleet

@Suite("CIFixReactor — react to failing CI and fix until green")
struct CIFixReactorTests {
    private let pr = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 30)

    private func failing() -> [PRCheck] {
        [PRCheck(name: "build", status: "COMPLETED", conclusion: "FAILURE", detailsURL: nil)]
    }
    private func green() -> [PRCheck] {
        [PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil)]
    }
    private func failingState() -> ShepherdState {
        ShepherdState(pullRequest: pr, phase: .watching, checks: PRCheckSummary(checks: failing()))
    }
    private func greenState() -> ShepherdState {
        ShepherdState(pullRequest: pr, phase: .watching, checks: PRCheckSummary(checks: green()))
    }

    private func makeReactor(
        spawner: StubWorkerSpawner,
        gate: StubOutwardActionGate,
        poller: SequencedPullRequestPoller,
        maxIterations: Int = 5
    ) -> CIFixReactor {
        CIFixReactor(spawner: spawner, gate: gate, poller: poller, maxIterations: maxIterations)
    }

    @Test("a check failure spawns a ci-fix worker scoped to the PR")
    func failureSpawnsWorker() async {
        let spawner = StubWorkerSpawner(producesFix: true)
        let gate = StubOutwardActionGate(verdict: .allowed)
        // First poll (during loop) is green so the loop ends immediately.
        let poller = SequencedPullRequestPoller([.checks(green())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller)

        let outcome = await reactor.ingest(failingState())

        #expect(spawner.spawnCount == 1)
        #expect(spawner.spawned.first?.pullRequest == pr)
        #expect(outcome == .greenSuccess)
    }

    @Test("a non-failing snapshot does not spawn a worker")
    func greenSnapshotDoesNotSpawn() async {
        let spawner = StubWorkerSpawner()
        let gate = StubOutwardActionGate()
        let poller = SequencedPullRequestPoller([.checks(green())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller)

        let outcome = await reactor.ingest(greenState())

        #expect(spawner.spawnCount == 0)
        #expect(outcome == nil)
    }

    @Test("the loop pushes fixes through the autonomy gate and stops on green")
    func loopPushesThenStopsOnGreen() async {
        let spawner = StubWorkerSpawner(producesFix: true)
        let gate = StubOutwardActionGate(verdict: .allowed)
        // red, red, green across the loop's re-polls.
        let poller = SequencedPullRequestPoller([
            .checks(failing()),
            .checks(failing()),
            .checks(green()),
        ])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller)

        let outcome = await reactor.runFixLoop(for: pr)

        #expect(outcome == .greenSuccess)
        // Pushed once per iteration before it went green (iterations 0 and 1).
        #expect(gate.requestCount == 3)
        #expect(gate.requested.allSatisfy {
            $0 == .pushFix(pullRequest: pr, branch: pr.repo)
        })
    }

    @Test("hitting the cap while still red flags the PR as needs attention")
    func capFlagsNeedsAttention() async {
        let spawner = StubWorkerSpawner(producesFix: true)
        let gate = StubOutwardActionGate(verdict: .allowed)
        // Always red.
        let poller = SequencedPullRequestPoller([.checks(failing())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller, maxIterations: 3)

        let outcome = await reactor.runFixLoop(for: pr)

        #expect(outcome.needsAttention == true)
        if case .needsAttention = outcome {} else {
            Issue.record("expected needsAttention, got \(outcome)")
        }
    }

    @Test("a denied push flags needs attention and does not loop further")
    func deniedPushFlagsNeedsAttention() async {
        let spawner = StubWorkerSpawner(producesFix: true)
        let gate = StubOutwardActionGate(verdict: .denied)
        let poller = SequencedPullRequestPoller([.checks(failing())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller, maxIterations: 5)

        let outcome = await reactor.runFixLoop(for: pr)

        #expect(outcome.needsAttention == true)
        // Stopped after the first denied push — no further iterations.
        #expect(gate.requestCount == 1)
    }

    @Test("a worker that produces no new commits stops the loop with needs attention")
    func noProgressStopsLoop() async {
        let spawner = StubWorkerSpawner(producesFix: false)
        let gate = StubOutwardActionGate(verdict: .allowed)
        // CI stays red across re-polls; without a no-progress guard the loop would
        // respawn a worker every iteration up to the cap (the infinite-respawn bug).
        let poller = SequencedPullRequestPoller([.checks(failing())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller, maxIterations: 5)

        let outcome = await reactor.runFixLoop(for: pr)

        // Stops immediately as needs-attention rather than looping to the cap.
        #expect(outcome.needsAttention == true)
        // The worker was attempted exactly once — no respawn / re-attempt.
        #expect(spawner.lastHandle?.attemptCount == 1)
        // No push was authorized (the worker produced nothing to push).
        #expect(gate.requestCount == 0)
    }

    @Test("no progress does not respawn: ingest stops after one no-op attempt")
    func noProgressDoesNotRespawnViaIngest() async {
        let spawner = StubWorkerSpawner(producesFix: false)
        let gate = StubOutwardActionGate(verdict: .allowed)
        let poller = SequencedPullRequestPoller([.checks(failing())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller, maxIterations: 5)

        let outcome = await reactor.ingest(failingState())

        #expect(outcome?.needsAttention == true)
        #expect(spawner.spawnCount == 1)
        #expect(spawner.lastHandle?.attemptCount == 1)
    }

    @Test("a worker that produces a fix turning CI green still stops on green")
    func progressThenGreenStopsOnGreen() async {
        let spawner = StubWorkerSpawner(producesFix: true)
        let gate = StubOutwardActionGate(verdict: .allowed)
        // The fix pushes, then the re-poll shows green.
        let poller = SequencedPullRequestPoller([.checks(green())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller, maxIterations: 5)

        let outcome = await reactor.runFixLoop(for: pr)

        #expect(outcome == .greenSuccess)
    }

    @Test("the same failure does not spawn a duplicate loop")
    func failureTransitionIsDeduped() async {
        let spawner = StubWorkerSpawner(producesFix: false)
        let gate = StubOutwardActionGate(verdict: .allowed)
        // Loop ends immediately on green so each ingest that triggers completes.
        let poller = SequencedPullRequestPoller([.checks(green())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller)

        _ = await reactor.ingest(failingState())
        // A second consecutive failing snapshot is the same failure, not a new
        // transition → no second spawn.
        let second = await reactor.ingest(failingState())

        #expect(spawner.spawnCount == 1)
        #expect(second == nil)
    }

    @Test("re-arming after green lets a fresh failure trigger again")
    func reArmsAfterGreen() async {
        let spawner = StubWorkerSpawner(producesFix: false)
        let gate = StubOutwardActionGate(verdict: .allowed)
        let poller = SequencedPullRequestPoller([.checks(green())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller)

        _ = await reactor.ingest(failingState())   // transition 1 → spawn
        _ = await reactor.ingest(greenState())     // re-arm
        _ = await reactor.ingest(failingState())   // transition 2 → spawn again

        #expect(spawner.spawnCount == 2)
    }

    @Test("outcomes() publishes the terminal outcome of a triggered loop")
    func outcomesStreamPublishes() async {
        let spawner = StubWorkerSpawner(producesFix: true)
        let gate = StubOutwardActionGate(verdict: .allowed)
        let poller = SequencedPullRequestPoller([.checks(green())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller)

        let stream = await reactor.outcomes()
        var iterator = stream.makeAsyncIterator()

        _ = await reactor.ingest(failingState())

        let published = await iterator.next()
        #expect(published == .greenSuccess)
    }

    // MARK: - Cancel stops the loop (regression for the runaway respawn)

    @Test("a cancelled worker stops the loop without spawning another iteration")
    func cancelledWorkerStopsLoop() async {
        // The worker reports cancelled on its FIRST attempt (the user hit ✕ / the
        // process was SIGKILLed mid-iteration). Without the fix, the loop treated a
        // cancel like "ran, no fix" and either advanced or only stopped as
        // needs-attention. It must instead stop as `.cancelled`.
        let spawner = StubWorkerSpawner(ciFixOutcomes: [.cancelled])
        let gate = StubOutwardActionGate(verdict: .allowed)
        // CI stays red so nothing else would stop the loop.
        let poller = SequencedPullRequestPoller([.checks(failing())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller, maxIterations: 5)

        let outcome = await reactor.runFixLoop(for: pr)

        #expect(outcome == .cancelled)
        // The single spawned worker was attempted exactly once — no respawn.
        #expect(spawner.spawnCount == 1)
        #expect(spawner.lastHandle?.attemptCount == 1)
        // A cancel is not a give-up: the PR is NOT flagged needs-attention.
        #expect(await reactor.isNeedingAttention(pr) == false)
        // Nothing was pushed for a cancelled attempt.
        #expect(gate.requestCount == 0)
    }

    @Test("a worker cancelled after producing one fix still stops, no extra spawn")
    func cancelAfterProgressStopsLoop() async {
        // Iteration 0 produces a fix (pushed), CI re-poll is still red so the loop
        // would normally continue; iteration 1's worker is cancelled. The loop must
        // stop as `.cancelled`, not advance to a third iteration.
        let spawner = StubWorkerSpawner(ciFixOutcomes: [.produced, .cancelled])
        let gate = StubOutwardActionGate(verdict: .allowed)
        let poller = SequencedPullRequestPoller([.checks(failing())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller, maxIterations: 5)

        let outcome = await reactor.runFixLoop(for: pr)

        #expect(outcome == .cancelled)
        // One ci-fix worker handle, attempted exactly twice (produced, cancelled).
        #expect(spawner.spawnCount == 1)
        #expect(spawner.lastHandle?.attemptCount == 2)
        // Pushed exactly once (for the single produced iteration), then stopped.
        #expect(gate.requestCount == 1)
        #expect(await reactor.isNeedingAttention(pr) == false)
    }

    @Test("cancel(for:) before the loop starts stops it immediately, no attempt")
    func cancelBeforeIterationStopsLoop() async {
        // A dismiss cascade calls cancel(for:) before the loop's first iteration:
        // the per-iteration guard stops it before any worker attempt runs.
        let spawner = StubWorkerSpawner(producesFix: true)
        let gate = StubOutwardActionGate(verdict: .allowed)
        let poller = SequencedPullRequestPoller([.checks(failing())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller, maxIterations: 5)

        await reactor.cancel(for: pr)
        let outcome = await reactor.runFixLoop(for: pr)

        #expect(outcome == .cancelled)
        // Stopped before attempting any fix or pushing.
        #expect(spawner.lastHandle?.attemptCount == 0)
        #expect(gate.requestCount == 0)
    }

    @Test("cancel is idempotent and final: a cancelled loop reports cancelled once")
    func cancelIsIdempotent() async {
        let spawner = StubWorkerSpawner(ciFixOutcomes: [.cancelled])
        let gate = StubOutwardActionGate(verdict: .allowed)
        let poller = SequencedPullRequestPoller([.checks(failing())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller, maxIterations: 5)

        // Pre-cancel, then run: idempotent — still exactly one cancelled outcome.
        await reactor.cancel(for: pr)
        let first = await reactor.runFixLoop(for: pr)
        #expect(first == .cancelled)

        // Cancelling again is harmless.
        await reactor.cancel(for: pr)
        await reactor.cancel(for: pr)
        #expect(await reactor.isNeedingAttention(pr) == false)
    }

    @Test("ingest of a cancelled loop does not flag needs-attention or re-trigger")
    func ingestCancelDoesNotFlagOrRespawn() async {
        let spawner = StubWorkerSpawner(ciFixOutcomes: [.cancelled])
        let gate = StubOutwardActionGate(verdict: .allowed)
        let poller = SequencedPullRequestPoller([.checks(failing())])
        let reactor = makeReactor(spawner: spawner, gate: gate, poller: poller, maxIterations: 5)

        let outcome = await reactor.ingest(failingState())
        #expect(outcome == .cancelled)
        #expect(spawner.spawnCount == 1)
        #expect(await reactor.isNeedingAttention(pr) == false)

        // A second identical failing snapshot must NOT spawn a replacement loop
        // for the cancelled PR (failing edge was cleared, so it is not a fresh
        // transition; one cancel = one stop).
        let second = await reactor.ingest(failingState())
        #expect(second == nil)
        #expect(spawner.spawnCount == 1)
    }
}
