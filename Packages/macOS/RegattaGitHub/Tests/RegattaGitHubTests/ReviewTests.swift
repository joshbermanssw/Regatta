import Testing
@testable import RegattaGitHub

@Suite("GitHubPoller — reviews (review summaries)")
struct ReviewTests {
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

    private static let reviewsJSON = """
    {
      "reviews": [
        {
          "id": "PRR_approve",
          "author": { "login": "alice" },
          "state": "APPROVED",
          "body": "Looks great, thanks for the thorough tests!",
          "submittedAt": "2026-06-21T12:00:00Z"
        },
        {
          "id": "PRR_changes",
          "author": { "login": "bob" },
          "state": "CHANGES_REQUESTED",
          "body": "Please handle the empty path case before merging.",
          "submittedAt": "2026-06-21T12:05:00Z"
        },
        {
          "id": "PRR_bare",
          "author": { "login": "carol" },
          "state": "APPROVED",
          "body": "",
          "submittedAt": "2026-06-21T12:10:00Z"
        }
      ]
    }
    """

    @Test("fetchReviews parses gh pr view --json reviews output")
    func fetchParses() async throws {
        let runner = RecordingRunner(outputs: [Self.reviewsJSON])
        let poller = GitHubPoller(commandRunner: runner)

        let reviews = try await poller.fetchReviews(
            owner: "joshbermanssw", repo: "regatta", prNumber: 42
        )

        #expect(reviews.count == 3)
        #expect(reviews[0].id == "PRR_approve")
        #expect(reviews[0].author == "alice")
        #expect(reviews[0].state == .approved)
        #expect(reviews[0].body == "Looks great, thanks for the thorough tests!")
        #expect(reviews[1].state == .changesRequested)
        #expect(reviews[2].state == .approved)
        #expect(reviews[2].body.isEmpty)

        let calls = await runner.recordedCalls()
        let args = try #require(calls.first)
        #expect(args.first == "pr")
        #expect(args.contains("view"))
        #expect(args.contains("42"))
        #expect(args.contains("--json"))
        #expect(args.contains("reviews"))
        #expect(args.contains("joshbermanssw/regatta"))
    }

    @Test("fetchReviews returns empty when there are no reviews")
    func fetchEmpty() async throws {
        let runner = RecordingRunner(outputs: ["{ \"reviews\": [] }"])
        let poller = GitHubPoller(commandRunner: runner)
        let reviews = try await poller.fetchReviews(owner: "o", repo: "r", prNumber: 1)
        #expect(reviews.isEmpty)
    }

    @Test("an unrecognised review state decodes as .other rather than failing")
    func unknownStateMapsToOther() async throws {
        let json = """
        { "reviews": [
          { "id": "PRR_x", "author": { "login": "alice" }, "state": "PENDING", "body": "wip", "submittedAt": "" }
        ] }
        """
        let runner = RecordingRunner(outputs: [json])
        let poller = GitHubPoller(commandRunner: runner)
        let reviews = try await poller.fetchReviews(owner: "o", repo: "r", prNumber: 1)
        #expect(reviews.first?.state == .other)
    }
}
