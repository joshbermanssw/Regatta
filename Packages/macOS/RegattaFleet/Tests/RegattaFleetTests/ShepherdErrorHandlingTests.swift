import Testing
import Foundation
import RegattaGitHub
@testable import RegattaFleet

/// Failure-mode behavior tests for the shepherd + ci-fix reactor (issue #35).
///
/// - **gh auth failure:** a poll that throws an auth error pauses the shepherd
///   (phase ``ShepherdPollPhase/paused(reason:retryAfter:)``) with a backoff
///   delay, preserving the last good data.
/// - **gh rate-limit:** a rate-limit error pauses + backs off exponentially:
///   consecutive failures grow the retry delay; a clean poll resets it.
/// - **CI never green:** the reactor flips the PR to needs-attention and then
///   stops auto-pushing — a subsequent failure does not spawn another fix loop.
@Suite("Shepherd + reactor — error handling (#35)")
struct ShepherdErrorHandlingTests {
    private let pr = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 35)

    private func failing() -> [PRCheck] {
        [PRCheck(name: "build", status: "COMPLETED", conclusion: "FAILURE", detailsURL: nil)]
    }
    private func failingState() -> ShepherdState {
        ShepherdState(pullRequest: pr, phase: .watching, checks: PRCheckSummary(checks: failing()))
    }
    private func greenState() -> ShepherdState {
        ShepherdState(
            pullRequest: pr,
            phase: .watching,
            checks: PRCheckSummary(checks: [
                PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil)
            ])
        )
    }

    // MARK: - gh auth failure → paused + backoff

    @Test("a gh auth failure pauses the shepherd with a backoff and preserves last good data")
    func authFailurePausesWithBackoff() async {
        // First poll succeeds (seeds good data), second poll throws an auth error.
        let goodChecks = [PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil)]
        let poller = FakePullRequestPoller(checks: goodChecks)
        let watcher = ShepherdWatcher(pullRequest: pr, poller: poller, pollInterval: .seconds(30))

        await watcher.pollOnce()
        let good = await watcher.state
        #expect(good.phase == .watching)
        #expect(good.checks.allSucceeded)

        // Now make `gh` fail with an authentication error.
        poller.set(checks: [], threads: [], error: .nonZeroExit(
            exitStatus: 1,
            stderr: "gh: To get started with GitHub CLI, please run: gh auth login\nauthentication required"
        ))
        await watcher.pollOnce()

        let paused = await watcher.state
        guard case .paused(let reason, let retryAfter) = paused.phase else {
            Issue.record("expected .paused; got \(paused.phase)")
            return
        }
        #expect(!reason.isEmpty)
        // First pause backs off by exactly one interval.
        #expect(retryAfter == .seconds(30))
        // Last good data is preserved across the failure.
        #expect(paused.checks.allSucceeded)
    }

    // MARK: - gh rate-limit → exponential backoff, reset on success

    @Test("consecutive rate-limit failures back off exponentially and a clean poll resets the streak")
    func rateLimitBacksOffExponentiallyThenResets() async {
        let poller = FakePullRequestPoller(error: .nonZeroExit(
            exitStatus: 1,
            stderr: "API rate limit exceeded for user. retry-after: 60"
        ))
        let watcher = ShepherdWatcher(pullRequest: pr, poller: poller, pollInterval: .seconds(10))

        await watcher.pollOnce()
        guard case .paused(_, let first) = await watcher.state.phase else {
            Issue.record("expected first .paused"); return
        }
        #expect(first == .seconds(10))   // 10 × 2^0

        await watcher.pollOnce()
        guard case .paused(_, let second) = await watcher.state.phase else {
            Issue.record("expected second .paused"); return
        }
        #expect(second == .seconds(20))  // 10 × 2^1

        await watcher.pollOnce()
        guard case .paused(_, let third) = await watcher.state.phase else {
            Issue.record("expected third .paused"); return
        }
        #expect(third == .seconds(40))   // 10 × 2^2

        // A clean poll clears the streak; a later failure starts at one interval.
        poller.set(checks: [], threads: [])
        await watcher.pollOnce()
        #expect(await watcher.state.phase == .watching)

        poller.set(checks: [], threads: [], error: .nonZeroExit(
            exitStatus: 1, stderr: "secondary rate limit"
        ))
        await watcher.pollOnce()
        guard case .paused(_, let reset) = await watcher.state.phase else {
            Issue.record("expected .paused after reset"); return
        }
        #expect(reset == .seconds(10))   // streak reset → 10 × 2^0
    }

    // MARK: - CI never green → needs attention → stops auto-pushing

    @Test("after CI never goes green the reactor flips to needs attention and stops auto-pushing")
    func ciNeverGreenStopsAutoPushing() async {
        let spawner = StubWorkerSpawner(producesFix: true)
        let gate = StubOutwardActionGate(verdict: .allowed)
        // Always red: the loop will exhaust its cap without going green.
        let poller = SequencedPullRequestPoller([.checks(failing())])
        let reactor = CIFixReactor(spawner: spawner, gate: gate, poller: poller, maxIterations: 2)

        // First red transition → fix loop runs, hits cap, flips to needs attention.
        let first = await reactor.ingest(failingState())
        #expect(first?.needsAttention == true)
        #expect(await reactor.isNeedingAttention(pr))
        let spawnsAfterFirst = spawner.spawnCount
        let pushesAfterFirst = gate.requestCount
        #expect(spawnsAfterFirst >= 1)

        // The PR re-arms on a green snapshot then fails again. Because the PR is
        // flagged needs-attention, the reactor must NOT spawn another fix loop or
        // push again — auto-push has stopped (issue #35 acceptance criterion).
        _ = await reactor.ingest(greenState())
        let second = await reactor.ingest(failingState())

        #expect(second == nil)
        #expect(spawner.spawnCount == spawnsAfterFirst)  // no new loop spawned
        #expect(gate.requestCount == pushesAfterFirst)   // no new push

        // Clearing the flag re-enables reaction.
        await reactor.clearNeedsAttention(for: pr)
        #expect(!(await reactor.isNeedingAttention(pr)))
    }
}
