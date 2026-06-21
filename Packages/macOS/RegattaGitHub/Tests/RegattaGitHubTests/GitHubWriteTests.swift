import Testing
@testable import RegattaGitHub

@Suite("GitHubPoller — review-thread writes")
struct GitHubWriteTests {
    /// A command runner that records the argument vectors it is asked to run.
    private actor RecordingRunner: GitHubCommandRunning {
        private(set) var calls: [[String]] = []
        private let result: String
        init(result: String = "{}") { self.result = result }
        func run(_ args: [String]) async throws -> String {
            calls.append(args)
            return result
        }
        func recordedCalls() -> [[String]] { calls }
    }

    @Test("replyToReviewThread issues the reply mutation with thread id and body as variables")
    func reply() async throws {
        let runner = RecordingRunner()
        let poller = GitHubPoller(commandRunner: runner)

        try await poller.replyToReviewThread(threadID: "THREAD_1", body: "Done in abc123.")

        let calls = await runner.recordedCalls()
        #expect(calls.count == 1)
        let args = try #require(calls.first)
        #expect(args.first == "api")
        #expect(args.contains("graphql"))
        // Thread id and body are passed as separate -f variables (not interpolated
        // into the query string), so arbitrary reply text cannot break the query.
        #expect(args.contains("threadId=THREAD_1"))
        #expect(args.contains("body=Done in abc123."))
        let query = try #require(args.first { $0.hasPrefix("query=") })
        #expect(query.contains("addPullRequestReviewThreadReply"))
    }

    @Test("resolveReviewThread issues the resolve mutation with the thread id")
    func resolve() async throws {
        let runner = RecordingRunner()
        let poller = GitHubPoller(commandRunner: runner)

        try await poller.resolveReviewThread(threadID: "THREAD_2")

        let calls = await runner.recordedCalls()
        #expect(calls.count == 1)
        let args = try #require(calls.first)
        #expect(args.contains("threadId=THREAD_2"))
        let query = try #require(args.first { $0.hasPrefix("query=") })
        #expect(query.contains("resolveReviewThread"))
    }

    @Test("a failing gh invocation propagates the error")
    func propagatesFailure() async {
        let fake = FakeGitHubCommandRunner(responses: [.failure(.timedOut)])
        let poller = GitHubPoller(commandRunner: fake)
        await #expect(throws: GitHubCommandError.timedOut) {
            try await poller.resolveReviewThread(threadID: "T")
        }
    }
}
