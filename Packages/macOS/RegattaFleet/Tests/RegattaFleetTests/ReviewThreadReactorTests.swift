import Testing
import RegattaGitHub
@testable import RegattaFleet

@Suite("ReviewThreadReactor — new-comment handling")
struct ReviewThreadReactorTests {
    private let pr = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 28)
    private let selfLogin = "joshbermanssw"

    private func makeReactor(
        spawner: StubWorkerSpawner = StubWorkerSpawner(),
        writer: StubPullRequestWriter = StubPullRequestWriter(),
        gate: StubGate = StubGate(),
        log: StubActivityLog = StubActivityLog(),
        login: String? = nil
    ) -> ReviewThreadReactor {
        ReviewThreadReactor(
            spawner: spawner,
            writer: writer,
            gate: gate,
            log: log,
            selfLogin: { login }
        )
    }

    @Test("a new actionable thread spawns a worker")
    func newThreadSpawnsWorker() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeState(pr, threads: [makeThread("T1")]))

        #expect(spawner.spawnCount == 1)
        #expect(spawner.requests.first?.thread.id == "T1")
        #expect(await reactor.handledThreadIDs == ["T1"])
    }

    @Test("the worker posts a reply and resolves the thread, routed through the gate")
    func replyAndResolveRoutedThroughGate() async {
        let spawner = StubWorkerSpawner(result: .init(pushedCodeChange: true, replyBody: "Fixed.", shouldResolve: true))
        let writer = StubPullRequestWriter()
        let gate = StubGate()
        let reactor = makeReactor(spawner: spawner, writer: writer, gate: gate)

        await reactor.react(to: makeState(pr, threads: [makeThread("T1")]))

        #expect(writer.replies.map(\.threadID) == ["T1"])
        #expect(writer.replies.first?.body == "Fixed.")
        #expect(writer.resolvedThreadIDs == ["T1"])
        // Every outward action was offered to the gate.
        #expect(gate.seenActions.contains(.replyToThread(threadID: "T1", body: "Fixed.")))
        #expect(gate.seenActions.contains(.resolveThread(threadID: "T1")))
        #expect(gate.seenActions.contains(.pushCodeChange(threadID: "T1")))
    }

    @Test("the same thread is handled only once across repeated polls")
    func idempotentAcrossPolls() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)
        let state = makeState(pr, threads: [makeThread("T1")])

        await reactor.react(to: state)
        await reactor.react(to: state) // identical second poll
        await reactor.react(to: makeState(pr, threads: [makeThread("T1"), makeThread("T1")])) // dup id

        #expect(spawner.spawnCount == 1)
    }

    @Test("a second, genuinely new thread on a later poll spawns a second worker")
    func newThreadOnLaterPoll() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeState(pr, threads: [makeThread("T1")]))
        await reactor.react(to: makeState(pr, threads: [makeThread("T1"), makeThread("T2")]))

        #expect(spawner.spawnCount == 2)
        #expect(spawner.requests.map(\.thread.id) == ["T1", "T2"])
    }

    @Test("resolved and outdated threads are ignored")
    func ignoresResolvedAndOutdated() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeState(pr, threads: [
            makeThread("R", resolved: true),
            makeThread("O", outdated: true),
            makeThread("E", comments: 0), // no comments
        ]))

        #expect(spawner.spawnCount == 0)
        #expect(await reactor.handledThreadIDs.isEmpty)
    }

    /// Bug 3: a resolved thread must spawn no worker even when it carries
    /// comments (the user saw resolved threads acted on and wants certainty).
    @Test("a resolved thread with comments spawns no worker")
    func resolvedThreadWithCommentsSpawnsNothing() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)

        await reactor.react(to: makeState(pr, threads: [
            makeThread("RESOLVED", resolved: true, comments: 3),
        ]))

        #expect(spawner.spawnCount == 0)
        #expect(await reactor.handledThreadIDs.isEmpty)
    }

    /// Bug 2(a): a thread whose actionable comment is authored by the current gh
    /// user must not spawn a worker (it is the user's own comment).
    @Test("a thread authored by the current user does NOT spawn a worker")
    func selfAuthoredThreadIsSkipped() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)

        await reactor.react(to: makeState(pr, threads: [
            makeThread("SELF", author: selfLogin),
        ]))

        #expect(spawner.spawnCount == 0)
        #expect(await reactor.handledThreadIDs.isEmpty)
    }

    /// Bug 2(b): a thread whose actionable comment is authored by a bot (login
    /// ending in `[bot]`, e.g. `vercel[bot]`) must not spawn a worker.
    @Test("a bot-authored thread does NOT spawn a worker")
    func botAuthoredThreadIsSkipped() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)

        await reactor.react(to: makeState(pr, threads: [
            makeThread("BOT", author: "vercel[bot]"),
        ]))

        #expect(spawner.spawnCount == 0)
        #expect(await reactor.handledThreadIDs.isEmpty)
    }

    /// Bug 2(c): if the LAST comment in a thread is authored by the current user,
    /// the thread is already answered and must not spawn a worker.
    @Test("a thread already answered by the current user is skipped")
    func alreadyAnsweredThreadIsSkipped() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)

        await reactor.react(to: makeState(pr, threads: [
            // reviewer asked, then the current user already replied.
            makeThread("ANSWERED", authors: ["0xharkirat", selfLogin]),
        ]))

        #expect(spawner.spawnCount == 0)
        #expect(await reactor.handledThreadIDs.isEmpty)
    }

    /// A genuine reviewer comment (not the current user, not a bot, unresolved,
    /// not yet answered) still spawns a worker.
    @Test("a genuine unanswered reviewer thread DOES spawn a worker")
    func genuineReviewerThreadSpawns() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner, login: selfLogin)

        await reactor.react(to: makeState(pr, threads: [
            makeThread("REAL", author: "0xharkirat"),
        ]))

        #expect(spawner.spawnCount == 1)
        #expect(await reactor.handledThreadIDs == ["REAL"])
    }

    @Test("a gate-suppressed thread is not marked handled and retries on the next poll")
    func gateSuppressionAllowsRetry() async {
        let spawner = StubWorkerSpawner(result: .init(pushedCodeChange: false, replyBody: "x", shouldResolve: true))
        // Deny the reply, which leaves the thread half-handled.
        var allowReplyNow = false
        let gate = StubGate(deny: { action in
            if case .replyToThread = action { return !allowReplyNow }
            return false
        })
        let writer = StubPullRequestWriter()
        let reactor = makeReactor(spawner: spawner, writer: writer, gate: gate)

        await reactor.react(to: makeState(pr, threads: [makeThread("T1")]))
        #expect(await reactor.handledThreadIDs.isEmpty)
        #expect(writer.resolvedThreadIDs.isEmpty) // not resolved when reply suppressed

        // Autonomy flips on; the next poll retries and completes.
        allowReplyNow = true
        await reactor.react(to: makeState(pr, threads: [makeThread("T1")]))
        #expect(await reactor.handledThreadIDs == ["T1"])
        #expect(writer.resolvedThreadIDs == ["T1"])
    }

    @Test("per-thread activity is logged")
    func activityLogged() async {
        let log = StubActivityLog()
        let spawner = StubWorkerSpawner(result: .init(pushedCodeChange: true, replyBody: "done", shouldResolve: true))
        let reactor = makeReactor(spawner: spawner, log: log)

        await reactor.react(to: makeState(pr, threads: [makeThread("T1")]))

        let events = log.events(forThread: "T1").map(\.event)
        #expect(events.contains(.spawnedWorker))
        #expect(events.contains(.pushedCodeChange))
        #expect(events.contains(.postedReply(body: "done")))
        #expect(events.contains(.resolvedThread))
    }

    @Test("a spawner failure leaves the thread unhandled and logs the failure")
    func spawnFailureRetries() async {
        struct Boom: Error {}
        let spawner = StubWorkerSpawner(error: Boom())
        let log = StubActivityLog()
        let reactor = makeReactor(spawner: spawner, log: log)

        await reactor.react(to: makeState(pr, threads: [makeThread("T1")]))

        #expect(await reactor.handledThreadIDs.isEmpty)
        let events = log.events(forThread: "T1").map(\.event)
        #expect(events.contains(where: { if case .failed = $0 { return true }; return false }))
    }

    @Test("observe drains a watcher stream end-to-end")
    func observeStream() async {
        let spawner = StubWorkerSpawner()
        let reactor = makeReactor(spawner: spawner)
        let stream = AsyncStream<ShepherdState> { continuation in
            continuation.yield(makeState(pr, threads: [makeThread("T1")]))
            continuation.yield(makeState(pr, threads: [makeThread("T1"), makeThread("T2")]))
            continuation.finish()
        }

        await reactor.observe(stream)

        #expect(spawner.spawnCount == 2)
        #expect(await reactor.handledThreadIDs == ["T1", "T2"])
    }
}
