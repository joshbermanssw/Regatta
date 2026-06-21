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
}
