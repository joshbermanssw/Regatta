import Testing
import RegattaGitHub
@testable import RegattaFleet

@Suite("CIFixLoopCondition — until checks green")
struct CIFixLoopConditionTests {
    private let pr = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 30)

    private func failing() -> [PRCheck] {
        [PRCheck(name: "build", status: "COMPLETED", conclusion: "FAILURE", detailsURL: nil)]
    }
    private func green() -> [PRCheck] {
        [PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil)]
    }

    @Test("continues while checks are red")
    func continuesOnRed() async {
        let poller = SequencedPullRequestPoller([.checks(failing())])
        let condition = CIFixLoopCondition(pullRequest: pr, poller: poller, maxIterations: 5)

        let decision = await condition.evaluate(iteration: 0)
        #expect(decision == .continueLooping)
        #expect(await condition.isGreen == false)
    }

    @Test("stops once checks are green")
    func stopsOnGreen() async {
        let poller = SequencedPullRequestPoller([.checks(green())])
        let condition = CIFixLoopCondition(pullRequest: pr, poller: poller, maxIterations: 5)

        let decision = await condition.evaluate(iteration: 0)
        #expect(decision == .stop)
        #expect(await condition.isGreen == true)
    }

    @Test("continues on red then stops when CI turns green")
    func redThenGreen() async {
        let poller = SequencedPullRequestPoller([
            .checks(failing()),
            .checks(failing()),
            .checks(green()),
        ])
        let condition = CIFixLoopCondition(pullRequest: pr, poller: poller, maxIterations: 5)

        #expect(await condition.evaluate(iteration: 0) == .continueLooping)
        #expect(await condition.evaluate(iteration: 1) == .continueLooping)
        #expect(await condition.evaluate(iteration: 2) == .stop)
        #expect(await condition.isGreen == true)
    }

    @Test("stops at the cap even while still red")
    func stopsAtCap() async {
        let poller = SequencedPullRequestPoller([.checks(failing())])
        let condition = CIFixLoopCondition(pullRequest: pr, poller: poller, maxIterations: 2)

        // iteration 0, 1 below cap → continue; iteration 2 == cap → stop, still red.
        #expect(await condition.evaluate(iteration: 0) == .continueLooping)
        #expect(await condition.evaluate(iteration: 1) == .continueLooping)
        #expect(await condition.evaluate(iteration: 2) == .stop)
        #expect(await condition.isGreen == false)
    }

    @Test("a transient poll failure is treated as not-green and continues")
    func transientFailureContinues() async {
        let poller = SequencedPullRequestPoller([.failure(.timedOut)])
        let condition = CIFixLoopCondition(pullRequest: pr, poller: poller, maxIterations: 5)

        let decision = await condition.evaluate(iteration: 0)
        #expect(decision == .continueLooping)
        #expect(await condition.isGreen == false)
    }
}
