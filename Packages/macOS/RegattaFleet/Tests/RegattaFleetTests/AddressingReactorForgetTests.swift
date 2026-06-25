import Testing
import RegattaGitHub
@testable import RegattaFleet

/// Behavior-level tests for the addressing reactors' **dismiss lifecycle** (I2).
///
/// Each addressing reactor must expose `forget(for:)` so a shepherd dismiss can
/// clear its per-PR `handled` / `inFlight` state **and** install a dismissed-guard
/// so a late snapshot (one already in flight when the dismiss landed) cannot
/// re-trigger work for a dismissed PR. Without this the reactors leaked per-PR
/// state across a dismiss/re-handoff and a stale snapshot could respawn a worker.
@Suite("Addressing reactors — forget(for:) clears per-PR state on dismiss (I2)")
struct AddressingReactorForgetTests {
    private let pr = PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: 11)
    private let otherPR = PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: 12)

    // MARK: - Review thread

    @Test("forget clears handled threads so a re-handoff re-addresses them")
    func reviewThreadForgetClearsHandled() async {
        let spawner = StubWorkerSpawner()
        let reactor = ReviewThreadReactor(
            spawner: spawner, writer: StubPullRequestWriter(), gate: StubGate(),
            log: StubActivityLog(), selfLogin: { nil }, headBranchResolver: { _ in "feature/x" }
        )
        let state = makeState(pr, threads: [makeThread("T1")])

        await reactor.react(to: state)
        #expect(await reactor.handledThreadIDs == ["T1"])

        await reactor.forget(for: pr)
        #expect(await reactor.handledThreadIDs.isEmpty)
    }

    @Test("after forget, a late snapshot for the dismissed PR does not re-trigger")
    func reviewThreadForgetGuardsLateSnapshot() async {
        let spawner = StubWorkerSpawner()
        let reactor = ReviewThreadReactor(
            spawner: spawner, writer: StubPullRequestWriter(), gate: StubGate(),
            log: StubActivityLog(), selfLogin: { nil }, headBranchResolver: { _ in "feature/x" }
        )

        await reactor.forget(for: pr)
        // A snapshot arriving for the just-dismissed PR must not spawn a worker.
        await reactor.react(to: makeState(pr, threads: [makeThread("T1")]))
        #expect(spawner.spawnCount == 0)
        #expect(await reactor.handledThreadIDs.isEmpty)

        // A different PR is unaffected by the dismissed-guard.
        await reactor.react(to: makeState(otherPR, threads: [makeThread("T9")]))
        #expect(spawner.spawnCount == 1)
    }

    // MARK: - Conversation comment

    @Test("forget clears handled comments and guards a late snapshot")
    func conversationForgetClearsAndGuards() async {
        let spawner = StubWorkerSpawner()
        let reactor = ConversationCommentReactor(
            spawner: spawner, writer: StubPullRequestWriter(), gate: StubGate(),
            log: StubConversationCommentActivityLog(), selfLogin: { "shepherd-bot" },
            headBranchResolver: { _ in "feature/x" }
        )
        await reactor.react(to: makeConvState(pr, comments: [makeComment("C1", author: "alice")]))
        #expect(await reactor.handledCommentIDs == ["C1"])

        await reactor.forget(for: pr)
        #expect(await reactor.handledCommentIDs.isEmpty)

        // A late snapshot for the dismissed PR must not respawn.
        await reactor.react(to: makeConvState(pr, comments: [makeComment("C2", author: "alice")]))
        #expect(spawner.conversationSpawnCount == 1, "no new spawn for a dismissed PR")
    }

    // MARK: - Review summary

    @Test("forget clears handled reviews and guards a late snapshot")
    func reviewSummaryForgetClearsAndGuards() async {
        let spawner = StubWorkerSpawner()
        let reactor = ReviewSummaryReactor(
            spawner: spawner, writer: StubPullRequestWriter(), gate: StubGate(),
            log: StubReviewSummaryActivityLog(), selfLogin: { "shepherd-bot" },
            headBranchResolver: { _ in "feature/x" }
        )
        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .changesRequested, body: "fix this"),
        ]))
        #expect(await reactor.handledReviewIDs == ["R1"])

        await reactor.forget(for: pr)
        #expect(await reactor.handledReviewIDs.isEmpty)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R2", author: "alice", state: .changesRequested, body: "more"),
        ]))
        #expect(spawner.reviewSpawnCount == 1, "no new spawn for a dismissed PR")
    }

    // MARK: - Re-arm after a fresh handoff

    @Test("a re-handoff (forget twice) re-arms a PR so a later snapshot works again")
    func forgetThenReHandoffReArms() async {
        let spawner = StubWorkerSpawner()
        let reactor = ReviewThreadReactor(
            spawner: spawner, writer: StubPullRequestWriter(), gate: StubGate(),
            log: StubActivityLog(), selfLogin: { nil }, headBranchResolver: { _ in "feature/x" }
        )
        await reactor.forget(for: pr) // dismiss
        await reactor.react(to: makeState(pr, threads: [makeThread("T1")]))
        #expect(spawner.spawnCount == 0)

        // Re-handoff clears the dismissed-guard so the reactor reacts again.
        await reactor.rearm(for: pr)
        await reactor.react(to: makeState(pr, threads: [makeThread("T1")]))
        #expect(spawner.spawnCount == 1)
    }
}
