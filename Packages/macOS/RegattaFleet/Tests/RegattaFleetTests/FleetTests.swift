import Testing
import RegattaGitHub
@testable import RegattaFleet

@Suite("Fleet — handoff & idempotency")
struct FleetTests {
    private let pr = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 28)

    /// Builds a Fleet that does not auto-start poll loops, so tests drive polls
    /// explicitly and avoid any timing dependence.
    private func makeFleet(_ poller: FakePullRequestPoller) -> Fleet {
        Fleet(autoStart: false) { ref in
            ShepherdWatcher(pullRequest: ref, poller: poller)
        }
    }

    @Test("handoff creates a persistent shepherd in the fleet")
    func handoffCreatesShepherd() async {
        let poller = FakePullRequestPoller()
        let fleet = makeFleet(poller)

        await fleet.handoff(pr)

        let snapshots = await fleet.currentSnapshots()
        #expect(snapshots.count == 1)
        let shepherd = try? #require(snapshots.first)
        #expect(shepherd?.kind == .shepherd)
        #expect(shepherd?.id == "manaflow-ai/cmux#28")
        #expect(await fleet.contains(pr) == true)
    }

    @Test("handing the same PR off twice does not create a duplicate")
    func handoffIsIdempotent() async {
        let poller = FakePullRequestPoller()
        let fleet = makeFleet(poller)

        let first = await fleet.handoff(pr)
        // A differently-cased ref resolves to the same identity.
        let dupeRef = PullRequestRef(owner: "Manaflow-AI", repo: "Cmux", number: 28)
        let second = await fleet.handoff(dupeRef)

        let snapshots = await fleet.currentSnapshots()
        #expect(snapshots.count == 1)
        #expect(first === second)
    }

    @Test("two distinct PRs produce two shepherds")
    func twoDistinctPRs() async {
        let poller = FakePullRequestPoller()
        let fleet = makeFleet(poller)

        await fleet.handoff(pr)
        await fleet.handoff(PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 99))

        let snapshots = await fleet.currentSnapshots()
        #expect(snapshots.count == 2)
    }

    @Test("polling a handed-off shepherd updates the fleet snapshot")
    func pollingUpdatesSnapshot() async {
        let poller = FakePullRequestPoller(
            checks: [PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil)],
            threads: []
        )
        let fleet = makeFleet(poller)

        let watcher = await fleet.handoff(pr)
        await watcher.pollOnce()

        // The fleet absorbs the watcher's published state via its fan-out task.
        // Poll the snapshot until the watching phase appears.
        var found: ShepherdState?
        for _ in 0..<50 {
            let snapshots = await fleet.currentSnapshots()
            if let s = snapshots.first, s.phase == .watching {
                found = s
                break
            }
            await Task.yield()
        }
        let state = try? #require(found)
        #expect(state?.phase == .watching)
        #expect(state?.checks.allSucceeded == true)
    }

    @Test("dismiss removes a shepherd from the fleet")
    func dismissRemovesShepherd() async {
        let poller = FakePullRequestPoller()
        let fleet = makeFleet(poller)

        await fleet.handoff(pr)
        #expect(await fleet.currentSnapshots().count == 1)

        await fleet.dismiss(pr)
        #expect(await fleet.currentSnapshots().isEmpty)
        #expect(await fleet.contains(pr) == false)
    }

    @Test("a new handoff defaults to staged autonomy mode")
    func handoffDefaultsToStaged() async {
        let fleet = makeFleet(FakePullRequestPoller())
        await fleet.handoff(pr)

        #expect(await fleet.autonomyMode(for: pr) == .staged)
        let snapshot = await fleet.currentSnapshots().first
        #expect(snapshot?.autonomyMode == .staged)
    }

    @Test("setting a PR's autonomy mode updates the snapshot and the gate")
    func setAutonomyModeUpdatesSnapshotAndGate() async {
        let fleet = makeFleet(FakePullRequestPoller())
        await fleet.handoff(pr)

        await fleet.setAutonomyMode(.auto, for: pr)

        #expect(await fleet.autonomyMode(for: pr) == .auto)
        let snapshot = await fleet.currentSnapshots().first
        #expect(snapshot?.autonomyMode == .auto)
        #expect(await fleet.autonomyGate.mode(for: pr) == .auto)
    }

    @Test("autonomy mode is isolated per shepherd")
    func autonomyModeIsPerPR() async {
        let fleet = makeFleet(FakePullRequestPoller())
        let other = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 99)
        await fleet.handoff(pr)
        await fleet.handoff(other)

        await fleet.setAutonomyMode(.auto, for: pr)

        #expect(await fleet.autonomyMode(for: pr) == .auto)
        #expect(await fleet.autonomyMode(for: other) == .staged)
    }

    @Test("snapshots() replays the current shepherd list to a new subscriber")
    func snapshotsReplays() async {
        let poller = FakePullRequestPoller()
        let fleet = makeFleet(poller)
        await fleet.handoff(pr)

        let stream = await fleet.snapshots()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.count == 1)
    }
}
