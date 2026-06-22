import Foundation
import Testing
@testable import RegattaPersistence
import RegattaFleet
import RegattaGitHub

/// A fake poller that records its calls and returns canned data, so a test can
/// prove a resumed shepherd actually resumed polling without any `gh` process.
private actor RecordingPoller: PullRequestPolling {
    private(set) var checkCalls: [(owner: String, repo: String, prNumber: Int)] = []
    private let checks: [PRCheck]
    private let threads: [ReviewThread]
    private let conversationComments: [PRConversationComment]
    private let login: String

    init(
        checks: [PRCheck],
        threads: [ReviewThread],
        conversationComments: [PRConversationComment] = [],
        login: String = "shepherd-bot"
    ) {
        self.checks = checks
        self.threads = threads
        self.conversationComments = conversationComments
        self.login = login
    }

    func fetchChecks(owner: String, repo: String, prNumber: Int) async throws -> [PRCheck] {
        checkCalls.append((owner, repo, prNumber))
        return checks
    }

    func fetchReviewThreads(owner: String, repo: String, prNumber: Int) async throws -> [ReviewThread] {
        threads
    }

    func fetchConversationComments(owner: String, repo: String, prNumber: Int) async throws -> [PRConversationComment] {
        conversationComments
    }

    func currentUserLogin() async throws -> String { login }

    func recordedCalls() -> [(owner: String, repo: String, prNumber: Int)] { checkCalls }
}

/// Tests that PR shepherds resume polling automatically on restore.
@Suite struct RegattaShepherdResumerTests {

    @Test func resumesOneWatcherPerPersistedShepherd() async {
        let pr1 = PullRequestRef(owner: "o", repo: "r", number: 1)
        let pr2 = PullRequestRef(owner: "o", repo: "r", number: 2)
        let snapshot = RegattaStateSnapshot(
            shepherds: [
                ShepherdState(pullRequest: pr1, phase: .watching, autonomyMode: .auto),
                ShepherdState(pullRequest: pr2, phase: .starting, autonomyMode: .staged),
            ],
            autonomyModes: [pr1.id: .auto, pr2.id: .staged]
        )
        let poller = RecordingPoller(checks: [], threads: [])
        let resumer = RegattaShepherdResumer(poller: poller, pollInterval: .seconds(3600))

        let resumed = await resumer.resume(from: snapshot)
        defer { Task { for r in resumed { await r.watcher.stop() } } }

        #expect(resumed.count == 2)
        #expect(Set(resumed.map(\.pullRequest.id)) == [pr1.id, pr2.id])
        // Autonomy modes restored from the snapshot map.
        #expect(resumed.first(where: { $0.pullRequest.id == pr1.id })?.autonomyMode == .auto)
        #expect(resumed.first(where: { $0.pullRequest.id == pr2.id })?.autonomyMode == .staged)
    }

    @Test func resumedWatcherActuallyPolls() async {
        let pr = PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: 34)
        let snapshot = RegattaStateSnapshot(
            shepherds: [ShepherdState(pullRequest: pr, phase: .watching)]
        )
        let poller = RecordingPoller(
            checks: [PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil)],
            threads: []
        )
        // Long interval so the auto-started loop's first poll is the only one we
        // depend on; we also drive an explicit poll to be deterministic.
        let resumer = RegattaShepherdResumer(poller: poller, pollInterval: .seconds(3600))

        let resumed = await resumer.resume(from: snapshot)
        let watcher = try! #require(resumed.first).watcher
        defer { Task { await watcher.stop() } }

        // Driving a poll cycle proves the watcher is live and wired to the poller.
        await watcher.pollOnce()
        let state = await watcher.state
        #expect(state.phase == .watching)
        #expect(state.checks.allSucceeded)

        let calls = await poller.recordedCalls()
        #expect(calls.contains { $0.owner == "joshbermanssw" && $0.prNumber == 34 })
    }

    @Test func fallsBackToShepherdAutonomyModeWhenMapMissing() async {
        let pr = PullRequestRef(owner: "o", repo: "r", number: 5)
        let snapshot = RegattaStateSnapshot(
            shepherds: [ShepherdState(pullRequest: pr, phase: .watching, autonomyMode: .auto)]
            // no autonomyModes entry
        )
        let resumer = RegattaShepherdResumer(
            poller: RecordingPoller(checks: [], threads: []),
            pollInterval: .seconds(3600)
        )
        let resumed = await resumer.resume(from: snapshot)
        defer { Task { for r in resumed { await r.watcher.stop() } } }
        #expect(resumed.first?.autonomyMode == .auto)
    }
}
