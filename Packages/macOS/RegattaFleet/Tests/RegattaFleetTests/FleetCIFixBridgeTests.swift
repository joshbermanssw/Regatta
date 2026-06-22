import Testing
import RegattaGitHub
@testable import RegattaFleet

@Suite("FleetCIFixBridge — Fleet failing checks drive the reactor")
struct FleetCIFixBridgeTests {
    private let pr = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 30)

    private func failing() -> [PRCheck] {
        [PRCheck(name: "build", status: "COMPLETED", conclusion: "FAILURE", detailsURL: nil)]
    }
    private func green() -> [PRCheck] {
        [PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil)]
    }

    @Test("a shepherd polling failing checks spawns a ci-fix worker via the bridge")
    func failingShepherdTriggersReactor() async {
        // Fleet shepherd sees a failing check on its poll.
        let fleetPoller = FakePullRequestPoller(checks: failing(), threads: [])
        let fleet = Fleet(autoStart: false) { ref in
            ShepherdWatcher(pullRequest: ref, poller: fleetPoller)
        }

        // Reactor's own loop re-polls and immediately sees green, so the loop ends.
        let spawner = StubWorkerSpawner(producesFix: true)
        let gate = StubOutwardActionGate(verdict: .allowed)
        let loopPoller = SequencedPullRequestPoller([.checks(green())])
        let reactor = CIFixReactor(spawner: spawner, gate: gate, poller: loopPoller)

        let bridge = FleetCIFixBridge(fleet: fleet, reactor: reactor)
        await bridge.start()

        let watcher = await fleet.handoff(pr)
        await watcher.pollOnce() // publishes a failing ShepherdState into the Fleet

        // Wait for the bridge to forward the failing snapshot and the reactor to spawn.
        var spawned = false
        for _ in 0..<200 {
            if spawner.spawnCount >= 1 { spawned = true; break }
            await Task.yield()
        }
        await bridge.stop()

        #expect(spawned)
        #expect(spawner.spawned.first?.pullRequest == pr)
    }

    @Test("a give-up loop raises the Fleet's needs-attention banner with a reason")
    func giveUpRaisesNeedsAttention() async {
        // Fleet shepherd sees failing checks on its poll.
        let fleetPoller = FakePullRequestPoller(checks: failing(), threads: [])
        let fleet = Fleet(autoStart: false) { ref in
            ShepherdWatcher(pullRequest: ref, poller: fleetPoller)
        }

        // Reactor's worker produces nothing → no-progress give-up; the loop's
        // re-poll stays red so the reason names the failing checks.
        let spawner = StubWorkerSpawner(producesFix: false)
        let gate = StubOutwardActionGate(verdict: .allowed)
        let loopPoller = SequencedPullRequestPoller([.checks(failing())])
        let reactor = CIFixReactor(spawner: spawner, gate: gate, poller: loopPoller)

        let bridge = FleetCIFixBridge(fleet: fleet, reactor: reactor)
        await bridge.start()

        let watcher = await fleet.handoff(pr)
        await watcher.pollOnce()

        // Wait for the bridge to forward the failing snapshot, run the loop, and
        // reflect the give-up outcome onto the Fleet.
        var reason: String?
        for _ in 0..<400 {
            if let r = await fleet.needsAttention(for: pr) { reason = r; break }
            await Task.yield()
        }
        await bridge.stop()

        let resolved = try? #require(reason)
        #expect(resolved?.contains("no code-level fix found") == true)
        #expect(resolved?.contains("build") == true)
    }

    @Test("a green-recovery loop clears a stale needs-attention banner")
    func greenRecoveryClearsNeedsAttention() async {
        let fleetPoller = FakePullRequestPoller(checks: failing(), threads: [])
        let fleet = Fleet(autoStart: false) { ref in
            ShepherdWatcher(pullRequest: ref, poller: fleetPoller)
        }
        // Pre-set a stale banner from an earlier give-up.
        await fleet.handoff(pr)
        await fleet.setNeedsAttention("stale give-up", for: pr)

        // The reactor's loop re-polls green immediately → greenSuccess.
        let spawner = StubWorkerSpawner(producesFix: true)
        let gate = StubOutwardActionGate(verdict: .allowed)
        let loopPoller = SequencedPullRequestPoller([.checks(green())])
        let reactor = CIFixReactor(spawner: spawner, gate: gate, poller: loopPoller)

        let bridge = FleetCIFixBridge(fleet: fleet, reactor: reactor)
        await bridge.start()

        let watcher = await fleet.handoff(pr)
        await watcher.pollOnce()

        var cleared = false
        for _ in 0..<400 {
            if await fleet.needsAttention(for: pr) == nil { cleared = true; break }
            await Task.yield()
        }
        await bridge.stop()

        #expect(cleared)
    }
}
