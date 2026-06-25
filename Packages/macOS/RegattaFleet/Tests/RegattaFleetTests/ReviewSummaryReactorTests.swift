import Testing
import RegattaGitHub
@testable import RegattaFleet

@Suite("ReviewSummaryReactor — actionable-review policy + skip rules")
struct ReviewSummaryReactorTests {
    private let pr = PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: 42)
    private let selfLogin = "shepherd-bot"

    private func makeReactor(
        spawner: StubWorkerSpawner = StubWorkerSpawner(),
        writer: StubPullRequestWriter = StubPullRequestWriter(),
        gate: StubGate = StubGate(),
        log: StubReviewSummaryActivityLog = StubReviewSummaryActivityLog(),
        login: String? = "shepherd-bot",
        headBranch: String? = "feature/x"
    ) -> ReviewSummaryReactor {
        ReviewSummaryReactor(
            spawner: spawner,
            writer: writer,
            gate: gate,
            log: log,
            selfLogin: { login },
            headBranchResolver: { _ in headBranch }
        )
    }

    // MARK: - Actionable states

    @Test("a CHANGES_REQUESTED review with a body spawns a worker")
    func changesRequestedSpawns() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .changesRequested, body: "Please handle empty input."),
        ]))

        #expect(spawner.reviewSpawnCount == 1)
        #expect(spawner.reviewRequests.first?.review.id == "R1")
        #expect(await reactor.handledReviewIDs == ["R1"])
    }

    @Test("a CHANGES_REQUESTED review with an empty body is still actionable (blocking)")
    func changesRequestedEmptyBodyStillSpawns() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .changesRequested, body: ""),
        ]))

        #expect(spawner.reviewSpawnCount == 1)
    }

    @Test("an APPROVED review with a substantive body spawns a worker")
    func approvedSubstantiveSpawns() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .approved,
                       body: "Approving, but please rename the helper to be clearer before merge."),
        ]))

        #expect(spawner.reviewSpawnCount == 1)
    }

    @Test("a COMMENTED review with a substantive body spawns a worker")
    func commentedSubstantiveSpawns() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .commented,
                       body: "Could you add a test for the timeout path?"),
        ]))

        #expect(spawner.reviewSpawnCount == 1)
    }

    // MARK: - Non-actionable states / bodies

    @Test("an APPROVED review with an empty body does NOT spawn")
    func approvedEmptyDoesNotSpawn() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .approved, body: ""),
        ]))

        #expect(spawner.reviewSpawnCount == 0)
        #expect(await reactor.handledReviewIDs.isEmpty)
    }

    @Test("an APPROVED review with a trivial LGTM body does NOT spawn")
    func approvedLGTMDoesNotSpawn() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .approved, body: "LGTM!"),
        ]))

        #expect(spawner.reviewSpawnCount == 0)
    }

    @Test("a COMMENTED review with an empty body does NOT spawn")
    func commentedEmptyDoesNotSpawn() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .commented, body: ""),
        ]))

        #expect(spawner.reviewSpawnCount == 0)
    }

    @Test("a DISMISSED review never spawns")
    func dismissedDoesNotSpawn() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .dismissed, body: "no longer relevant"),
        ]))

        #expect(spawner.reviewSpawnCount == 0)
    }

    // MARK: - Author skip rules (reused ShepherdAuthorPolicy)

    @Test("a self-authored review does NOT spawn (loop guard)")
    func selfAuthoredDoesNotSpawn() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: selfLogin, state: .changesRequested, body: "fix this"),
        ]))

        #expect(spawner.reviewSpawnCount == 0)
        #expect(await reactor.handledReviewIDs.isEmpty)
    }

    @Test("a bot-authored review does NOT spawn")
    func botAuthoredDoesNotSpawn() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "coderabbit[bot]", state: .changesRequested, body: "fix this"),
        ]))

        #expect(spawner.reviewSpawnCount == 0)
    }

    // MARK: - Already-answered (newer self review supersedes)

    @Test("a review the user already superseded with a later review is skipped")
    func supersededByLaterSelfReviewIsSkipped() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("ASK", author: "alice", state: .changesRequested, body: "fix this"),
            makeReview("MINE", author: selfLogin, state: .commented, body: "addressed"),
        ]))

        #expect(spawner.reviewSpawnCount == 0)
        #expect(await reactor.handledReviewIDs.isEmpty)
    }

    @Test("a review submitted after the user's own review still spawns")
    func reviewAfterSelfReviewStillSpawns() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("MINE", author: selfLogin, state: .commented, body: "addressed"),
            makeReview("FOLLOWUP", author: "alice", state: .changesRequested, body: "one more thing"),
        ]))

        #expect(spawner.reviewSpawnCount == 1)
        #expect(spawner.reviewRequests.map(\.review.id) == ["FOLLOWUP"])
    }

    // MARK: - Idempotency

    @Test("the same review is handled only once across repeated polls")
    func idempotentAcrossPolls() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)
        let state = makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .changesRequested, body: "fix this"),
        ])

        await reactor.react(to: state)
        await reactor.react(to: state)

        #expect(spawner.reviewSpawnCount == 1)
    }

    @Test("a second, genuinely new review on a later poll spawns a second worker")
    func newReviewOnLaterPoll() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .changesRequested, body: "fix this"),
        ]))
        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .changesRequested, body: "fix this"),
            makeReview("R2", author: "bob", state: .commented, body: "and please add a test"),
        ]))

        #expect(spawner.reviewSpawnCount == 2)
        #expect(spawner.reviewRequests.map(\.review.id) == ["R1", "R2"])
    }

    // MARK: - Outward actions + gate

    @Test("the worker's reply is posted, routed through the gate")
    func replyRoutedThroughGate() async {
        let spawner = StubWorkerSpawner(
            reviewResult: .init(pushedCodeChange: true, replyBody: "Addressed in a follow-up commit.")
        )
        let writer = StubPullRequestWriter()
        let gate = StubGate()
        let reactor = makeReactor(spawner: spawner, writer: writer, gate: gate)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .changesRequested, body: "fix this"),
        ]))

        #expect(writer.conversationComments.map(\.body) == ["Addressed in a follow-up commit."])
        #expect(gate.seenActions.contains(.replyToReview(reviewID: "R1", body: "Addressed in a follow-up commit.")))
        #expect(gate.seenActions.contains(.pushReviewChange(reviewID: "R1", branch: "feature/x")))
    }

    @Test("a pure approval the worker reports nothing-to-do posts no reply but is handled")
    func nothingToDoApprovalPostsNoReply() async {
        let spawner = StubWorkerSpawner(
            reviewResult: .init(pushedCodeChange: false, replyBody: nil)
        )
        let writer = StubPullRequestWriter()
        let log = StubReviewSummaryActivityLog()
        let reactor = makeReactor(spawner: spawner, writer: writer, log: log)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .approved,
                       body: "Approving — and consider documenting the new flag."),
        ]))

        #expect(spawner.reviewSpawnCount == 1)
        #expect(writer.conversationComments.isEmpty)
        #expect(await reactor.handledReviewIDs == ["R1"])
        #expect(log.events(forReview: "R1").map(\.event).contains(.nothingToDo))
    }

    @Test("a gate-suppressed reply leaves the review unhandled and retries")
    func gateSuppressionAllowsRetry() async {
        let spawner = StubWorkerSpawner(
            reviewResult: .init(pushedCodeChange: false, replyBody: "x")
        )
        var allowReplyNow = false
        let gate = StubGate(deny: { action in
            if case .replyToReview = action { return !allowReplyNow }
            return false
        })
        let writer = StubPullRequestWriter()
        let reactor = makeReactor(spawner: spawner, writer: writer, gate: gate)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .changesRequested, body: "fix this"),
        ]))
        #expect(await reactor.handledReviewIDs.isEmpty)
        #expect(writer.conversationComments.isEmpty)

        allowReplyNow = true
        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .changesRequested, body: "fix this"),
        ]))
        #expect(await reactor.handledReviewIDs == ["R1"])
        #expect(writer.conversationComments.map(\.body) == ["x"])
    }

    @Test("a spawner failure leaves the review unhandled and logs the failure")
    func spawnFailureRetries() async {
        struct Boom: Error {}
        let spawner = StubWorkerSpawner(reviewError: Boom())
        let log = StubReviewSummaryActivityLog()
        let reactor = makeReactor(spawner: spawner, log: log)

        await reactor.react(to: makeReviewState(pr, reviews: [
            makeReview("R1", author: "alice", state: .changesRequested, body: "fix this"),
        ]))

        #expect(await reactor.handledReviewIDs.isEmpty)
        #expect(log.events(forReview: "R1").map(\.event).contains(where: {
            if case .failed = $0 { return true }; return false
        }))
    }

    @Test("observe drains a watcher stream end-to-end, skipping the shepherd's own reviews")
    func observeStream() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)
        let stream = AsyncStream<ShepherdState> { continuation in
            continuation.yield(makeReviewState(pr, reviews: [
                makeReview("R1", author: "alice", state: .changesRequested, body: "fix this"),
            ]))
            continuation.yield(makeReviewState(pr, reviews: [
                makeReview("R1", author: "alice", state: .changesRequested, body: "fix this"),
                makeReview("SELF", author: selfLogin, state: .commented, body: "addressed"),
                makeReview("R2", author: "bob", state: .commented, body: "please add a test"),
            ]))
            continuation.finish()
        }

        await reactor.observe(stream)

        #expect(spawner.reviewSpawnCount == 2)
        #expect(await reactor.handledReviewIDs == ["R1", "R2"])
    }
}
