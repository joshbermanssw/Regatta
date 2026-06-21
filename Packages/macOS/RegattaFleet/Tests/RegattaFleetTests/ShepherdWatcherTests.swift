import Testing
import RegattaGitHub
@testable import RegattaFleet

@Suite("ShepherdWatcher — polling & state")
struct ShepherdWatcherTests {
    private let pr = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 28)

    @Test("initial state is the starting phase before any poll")
    func initialState() async {
        let poller = FakePullRequestPoller()
        let watcher = ShepherdWatcher(pullRequest: pr, poller: poller)
        let state = await watcher.state
        #expect(state.phase == .starting)
        #expect(state.checks.checks.isEmpty)
        #expect(state.reviewThreads.isEmpty)
        #expect(state.kind == .shepherd)
    }

    @Test("a single poll publishes checks and review threads")
    func pollPublishesData() async {
        let poller = FakePullRequestPoller(
            checks: [
                PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil),
                PRCheck(name: "test", status: "IN_PROGRESS", conclusion: nil, detailsURL: nil),
            ],
            threads: [
                ReviewThread(id: "T1", isResolved: false, isOutdated: false, path: "a.swift", comments: []),
                ReviewThread(id: "T2", isResolved: true, isOutdated: false, path: "b.swift", comments: []),
            ]
        )
        let watcher = ShepherdWatcher(pullRequest: pr, poller: poller)
        await watcher.pollOnce()

        let state = await watcher.state
        #expect(state.phase == .watching)
        #expect(state.checks.checks.count == 2)
        #expect(state.checks.anyPending == true)
        #expect(state.reviewThreads.count == 2)
        #expect(state.unresolvedThreadCount == 1)
    }

    @Test("a failed poll enters .failed but preserves last good data")
    func failedPollPreservesData() async {
        let poller = FakePullRequestPoller(
            checks: [PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil)],
            threads: []
        )
        let watcher = ShepherdWatcher(pullRequest: pr, poller: poller)
        await watcher.pollOnce()
        #expect(await watcher.state.phase == .watching)

        poller.set(checks: [], threads: [], error: .timedOut)
        await watcher.pollOnce()

        let state = await watcher.state
        if case .failed = state.phase {
            // expected
        } else {
            Issue.record("Expected .failed phase, got \(state.phase)")
        }
        // Last good checks are preserved across the failure.
        #expect(state.checks.checks.count == 1)
    }

    @Test("states() replays the current snapshot to a new subscriber")
    func statesReplaysCurrent() async {
        let poller = FakePullRequestPoller(
            checks: [PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil)],
            threads: []
        )
        let watcher = ShepherdWatcher(pullRequest: pr, poller: poller)
        await watcher.pollOnce()

        let stream = await watcher.states()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.phase == .watching)
        #expect(first?.checks.checks.count == 1)
    }
}
