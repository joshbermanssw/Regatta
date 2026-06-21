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
}
