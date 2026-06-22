import Testing
import RegattaGitHub
@testable import RegattaFleet

@Suite("ConversationCommentReactor — new-comment handling + self-reply loop guard")
struct ConversationCommentReactorTests {
    private let pr = PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: 42)
    private let selfLogin = "shepherd-bot"

    private func makeReactor(
        spawner: StubWorkerSpawner = StubWorkerSpawner(),
        writer: StubPullRequestWriter = StubPullRequestWriter(),
        gate: StubGate = StubGate(),
        log: StubConversationCommentActivityLog = StubConversationCommentActivityLog(),
        login: String? = "shepherd-bot"
    ) -> ConversationCommentReactor {
        ConversationCommentReactor(
            spawner: spawner,
            writer: writer,
            gate: gate,
            log: log,
            selfLogin: { login }
        )
    }

    @Test("a new comment from someone else spawns a worker")
    func newCommentSpawnsWorker() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeConvState(pr, comments: [makeComment("C1", author: "alice")]))

        #expect(spawner.conversationSpawnCount == 1)
        #expect(spawner.conversationRequests.first?.comment.id == "C1")
        #expect(await reactor.handledCommentIDs == ["C1"])
    }

    /// THE loop guard: a comment authored by the authenticated `gh` user (the
    /// shepherd's own reply) must NOT spawn a worker, otherwise the shepherd
    /// replies to its own replies forever.
    @Test("a self-authored comment does NOT spawn a worker (loop guard)")
    func selfAuthoredCommentIsSkipped() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)

        await reactor.react(to: makeConvState(pr, comments: [
            makeComment("SELF", author: selfLogin),
        ]))

        #expect(spawner.conversationSpawnCount == 0)
        #expect(await reactor.handledCommentIDs.isEmpty)
    }

    /// A real comment followed by the current user's own reply is *already
    /// answered* (rule 2c): the user has responded after it, so it must not spawn
    /// a worker. (The newer-comment-after-reply case is covered separately.)
    @Test("a real comment the user already replied to after is not re-actioned")
    func realCommentBeforeSelfReplyIsAnswered() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)

        await reactor.react(to: makeConvState(pr, comments: [
            makeComment("OTHER", author: "alice"),
            makeComment("MINE", author: selfLogin),
        ]))

        #expect(spawner.conversationSpawnCount == 0)
        #expect(await reactor.handledCommentIDs.isEmpty)
    }

    /// A real comment that arrives *after* the user's last reply is still
    /// actionable — earlier self replies do not answer later questions.
    @Test("a real comment after the user's reply spawns a worker")
    func realCommentAfterSelfReplyStillSpawns() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)

        await reactor.react(to: makeConvState(pr, comments: [
            makeComment("MINE", author: selfLogin),
            makeComment("OTHER", author: "alice"),
        ]))

        #expect(spawner.conversationSpawnCount == 1)
        #expect(spawner.conversationRequests.map(\.comment.id) == ["OTHER"])
    }

    @Test("the worker's reply is posted as a conversation comment, routed through the gate")
    func replyRoutedThroughGate() async {
        let spawner = StubWorkerSpawner(
            conversationResult: .init(pushedCodeChange: true, replyBody: "Done.")
        )
        let writer = StubPullRequestWriter()
        let gate = StubGate()
        let reactor = makeReactor(spawner: spawner, writer: writer, gate: gate)

        await reactor.react(to: makeConvState(pr, comments: [makeComment("C1", author: "alice")]))

        #expect(writer.conversationComments.map(\.body) == ["Done."])
        #expect(writer.conversationComments.first?.prNumber == pr.number)
        #expect(gate.seenActions.contains(.replyToConversation(commentID: "C1", body: "Done.")))
        #expect(gate.seenActions.contains(.pushConversationChange(commentID: "C1")))
    }

    @Test("the same comment is handled only once across repeated polls")
    func idempotentAcrossPolls() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)
        let state = makeConvState(pr, comments: [makeComment("C1", author: "alice")])

        await reactor.react(to: state)
        await reactor.react(to: state) // identical second poll
        // duplicate id in the same poll
        await reactor.react(to: makeConvState(pr, comments: [
            makeComment("C1", author: "alice"), makeComment("C1", author: "alice"),
        ]))

        #expect(spawner.conversationSpawnCount == 1)
    }

    @Test("a second, genuinely new comment on a later poll spawns a second worker")
    func newCommentOnLaterPoll() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeConvState(pr, comments: [makeComment("C1", author: "alice")]))
        await reactor.react(to: makeConvState(pr, comments: [
            makeComment("C1", author: "alice"), makeComment("C2", author: "bob"),
        ]))

        #expect(spawner.conversationSpawnCount == 2)
        #expect(spawner.conversationRequests.map(\.comment.id) == ["C1", "C2"])
    }

    /// Bug 2(b): a comment authored by a bot (login ending in `[bot]`, e.g.
    /// `vercel[bot]`) must not spawn a worker — automated comments aren't
    /// actionable.
    @Test("a bot-authored comment does NOT spawn a worker")
    func botAuthoredCommentIsSkipped() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeConvState(pr, comments: [
            makeComment("BOT", author: "vercel[bot]"),
        ]))

        #expect(spawner.conversationSpawnCount == 0)
        #expect(await reactor.handledCommentIDs.isEmpty)
    }

    /// Bug 2(c): if the current user has already replied **after** a comment, the
    /// comment is already answered and must not spawn a worker.
    @Test("a comment the current user already replied to is skipped")
    func alreadyAnsweredCommentIsSkipped() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)

        // alice asked; the current user (shepherd) already replied afterwards.
        await reactor.react(to: makeConvState(pr, comments: [
            makeComment("ASK", author: "alice"),
            makeComment("MYREPLY", author: selfLogin),
        ]))

        #expect(spawner.conversationSpawnCount == 0)
        #expect(await reactor.handledCommentIDs.isEmpty)
    }

    /// The "already answered" guard must not swallow a *newer* comment that
    /// arrived after the current user's reply — that one is still actionable.
    @Test("a new comment after the current user's reply still spawns")
    func newCommentAfterSelfReplyStillSpawns() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)

        await reactor.react(to: makeConvState(pr, comments: [
            makeComment("ASK", author: "alice"),
            makeComment("MYREPLY", author: selfLogin),
            makeComment("FOLLOWUP", author: "alice"),
        ]))

        #expect(spawner.conversationSpawnCount == 1)
        #expect(spawner.conversationRequests.map(\.comment.id) == ["FOLLOWUP"])
    }

    @Test("an empty-bodied comment is ignored")
    func ignoresEmptyComment() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeConvState(pr, comments: [
            makeComment("EMPTY", author: "alice", body: ""),
        ]))

        #expect(spawner.conversationSpawnCount == 0)
    }

    @Test("a gate-suppressed comment is not marked handled and retries on the next poll")
    func gateSuppressionAllowsRetry() async {
        let spawner = StubWorkerSpawner(
            conversationResult: .init(pushedCodeChange: false, replyBody: "x")
        )
        var allowReplyNow = false
        let gate = StubGate(deny: { action in
            if case .replyToConversation = action { return !allowReplyNow }
            return false
        })
        let writer = StubPullRequestWriter()
        let reactor = makeReactor(spawner: spawner, writer: writer, gate: gate)

        await reactor.react(to: makeConvState(pr, comments: [makeComment("C1", author: "alice")]))
        #expect(await reactor.handledCommentIDs.isEmpty)
        #expect(writer.conversationComments.isEmpty) // reply suppressed

        // Autonomy flips on; the next poll retries and completes.
        allowReplyNow = true
        await reactor.react(to: makeConvState(pr, comments: [makeComment("C1", author: "alice")]))
        #expect(await reactor.handledCommentIDs == ["C1"])
        #expect(writer.conversationComments.map(\.body) == ["x"])
    }

    @Test("per-comment activity is logged")
    func activityLogged() async {
        let log = StubConversationCommentActivityLog()
        let spawner = StubWorkerSpawner(
            conversationResult: .init(pushedCodeChange: true, replyBody: "done")
        )
        let reactor = makeReactor(spawner: spawner, log: log)

        await reactor.react(to: makeConvState(pr, comments: [makeComment("C1", author: "alice")]))

        let events = log.events(forComment: "C1").map(\.event)
        #expect(events.contains(.spawnedWorker))
        #expect(events.contains(.pushedCodeChange))
        #expect(events.contains(.postedReply(body: "done")))
    }

    @Test("a spawner failure leaves the comment unhandled and logs the failure")
    func spawnFailureRetries() async {
        struct Boom: Error {}
        let spawner = StubWorkerSpawner(conversationError: Boom())
        let log = StubConversationCommentActivityLog()
        let reactor = makeReactor(spawner: spawner, log: log)

        await reactor.react(to: makeConvState(pr, comments: [makeComment("C1", author: "alice")]))

        #expect(await reactor.handledCommentIDs.isEmpty)
        let events = log.events(forComment: "C1").map(\.event)
        #expect(events.contains(where: { if case .failed = $0 { return true }; return false }))
    }

    @Test("observe drains a watcher stream end-to-end, skipping the shepherd's own replies")
    func observeStream() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)
        let stream = AsyncStream<ShepherdState> { continuation in
            continuation.yield(makeConvState(pr, comments: [makeComment("C1", author: "alice")]))
            continuation.yield(makeConvState(pr, comments: [
                makeComment("C1", author: "alice"),
                makeComment("SELF", author: selfLogin), // shepherd's own reply
                makeComment("C2", author: "bob"),
            ]))
            continuation.finish()
        }

        await reactor.observe(stream)

        #expect(spawner.conversationSpawnCount == 2)
        #expect(await reactor.handledCommentIDs == ["C1", "C2"])
    }
}
