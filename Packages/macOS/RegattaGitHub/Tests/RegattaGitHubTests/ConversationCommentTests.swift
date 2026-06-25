import Testing
@testable import RegattaGitHub

@Suite("GitHubPoller — conversation comments")
struct ConversationCommentTests {
    /// A command runner that records the argument vectors it is asked to run and
    /// returns scripted outputs in order.
    private actor RecordingRunner: GitHubCommandRunning {
        private(set) var calls: [[String]] = []
        private var outputs: [String]
        init(outputs: [String]) { self.outputs = outputs }
        func run(_ args: [String]) async throws -> String {
            calls.append(args)
            return outputs.isEmpty ? "" : outputs.removeFirst()
        }
        func recordedCalls() -> [[String]] { calls }
    }

    private static let commentsJSON = """
    [
      {
        "id": 1001,
        "body": "Can you also handle the empty case?",
        "user": { "login": "alice" },
        "html_url": "https://github.com/joshbermanssw/regatta/pull/42#issuecomment-1001",
        "created_at": "2026-06-21T12:00:00Z"
      },
      {
        "id": 1002,
        "body": "On it — addressed in a follow-up commit.",
        "user": { "login": "shepherd-bot" },
        "html_url": "https://github.com/joshbermanssw/regatta/pull/42#issuecomment-1002",
        "created_at": "2026-06-21T12:05:00Z"
      }
    ]
    """

    @Test("fetchConversationComments parses the issue-comments endpoint output")
    func fetchParses() async throws {
        let runner = RecordingRunner(outputs: [Self.commentsJSON])
        let poller = GitHubPoller(commandRunner: runner)

        let comments = try await poller.fetchConversationComments(
            owner: "joshbermanssw", repo: "regatta", prNumber: 42
        )

        #expect(comments.count == 2)
        #expect(comments[0].id == "1001")
        #expect(comments[0].author == "alice")
        #expect(comments[0].body == "Can you also handle the empty case?")
        #expect(comments[1].author == "shepherd-bot")

        let calls = await runner.recordedCalls()
        let args = try #require(calls.first)
        #expect(args.first == "api")
        #expect(args.contains("repos/joshbermanssw/regatta/issues/42/comments"))
    }

    @Test("fetchConversationComments returns empty for an empty array")
    func fetchEmpty() async throws {
        let runner = RecordingRunner(outputs: ["[]"])
        let poller = GitHubPoller(commandRunner: runner)
        let comments = try await poller.fetchConversationComments(
            owner: "o", repo: "r", prNumber: 1
        )
        #expect(comments.isEmpty)
    }

    @Test("currentUserLogin resolves and caches the authenticated login")
    func loginCached() async throws {
        let runner = RecordingRunner(outputs: ["shepherd-bot\n"])
        let poller = GitHubPoller(commandRunner: runner)

        let first = try await poller.currentUserLogin()
        let second = try await poller.currentUserLogin()

        #expect(first == "shepherd-bot")
        #expect(second == "shepherd-bot")
        // Cached: only one `gh api user` call despite two reads.
        let calls = await runner.recordedCalls()
        #expect(calls.count == 1)
        let args = try #require(calls.first)
        #expect(args.contains("user"))
    }

    @Test("postConversationComment posts via gh pr comment with the body")
    func postComment() async throws {
        let runner = RecordingRunner(outputs: [""])
        let poller = GitHubPoller(commandRunner: runner)

        try await poller.postConversationComment(
            owner: "joshbermanssw", repo: "regatta", prNumber: 42, body: "Addressed `that` & more."
        )

        let calls = await runner.recordedCalls()
        let args = try #require(calls.first)
        #expect(args.first == "pr")
        #expect(args.contains("comment"))
        #expect(args.contains("42"))
        #expect(args.contains("--repo"))
        #expect(args.contains("joshbermanssw/regatta"))
        // The body is passed as the single-token `--body=<value>` form so shell
        // metacharacters are inert and a leading dash can't be misparsed as a flag.
        #expect(args.contains("--body=Addressed `that` & more."))
        // It must NOT be split into a separate `--body` flag + value token.
        #expect(!args.contains("--body"))
    }

    @Test("postConversationComment passes a dash-leading body as one --body= token")
    func postCommentDashLeadingBody() async throws {
        let runner = RecordingRunner(outputs: [""])
        let poller = GitHubPoller(commandRunner: runner)

        // A markdown bullet list begins with "- ", which `gh` would treat as an
        // unknown flag if the body were passed as a separate argument token.
        let body = "- fixed the null check\n- added a test"
        try await poller.postConversationComment(
            owner: "o", repo: "r", prNumber: 7, body: body
        )

        let calls = await runner.recordedCalls()
        let args = try #require(calls.first)
        #expect(args.contains("--body=\(body)"))
        // The dash-leading body must never appear as its own argument token.
        #expect(!args.contains(body))
    }
}
