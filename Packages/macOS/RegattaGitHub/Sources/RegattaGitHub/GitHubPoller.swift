/// A backend polling actor that fetches CI check statuses and review threads
/// for a pull request by shelling out to `gh`.
///
/// `GitHubPoller` is an `actor` — all mutable state is actor-isolated and
/// calls are `async`. Callers `await` individual fetches; the actor serialises
/// concurrent calls naturally.
///
/// Inject a custom ``GitHubCommandRunning`` to replace real `gh` invocations
/// with a fake in tests:
///
/// ```swift
/// // Production
/// let poller = GitHubPoller(commandRunner: GitHubCommandRunner())
///
/// // Tests
/// let poller = GitHubPoller(commandRunner: FakeGitHubCommandRunner(responses: [...]))
/// ```
///
/// ## GraphQL review-thread query
/// `fetchReviewThreads` issues a GraphQL query via `gh api graphql`. The
/// expected JSON shape is:
/// ```json
/// {
///   "data": {
///     "repository": {
///       "pullRequest": {
///         "reviewThreads": {
///           "nodes": [
///             {
///               "id": "...", "isResolved": false, "isOutdated": false,
///               "path": "Sources/Foo.swift",
///               "comments": { "nodes": [{ "id": "...", "body": "...", "author": { "login": "..." }, "url": "..." }] }
///             }
///           ]
///         }
///       }
///     }
///   }
/// }
/// ```
public actor GitHubPoller {
    private let commandRunner: any GitHubCommandRunning

    /// Creates a poller backed by `commandRunner`.
    ///
    /// - Parameter commandRunner: The strategy used to invoke `gh`; defaults to the
    ///   production runner that shells out to the real CLI.
    public init(commandRunner: any GitHubCommandRunning = GitHubCommandRunner()) {
        self.commandRunner = commandRunner
    }

    // MARK: - Check statuses

    /// Fetches the CI check statuses for a pull request.
    ///
    /// Shells out to:
    /// ```
    /// gh pr view <prNumber> --repo <owner>/<repo> --json statusCheckRollup
    /// ```
    ///
    /// - Parameters:
    ///   - owner: The repository owner (user or organisation) on GitHub.
    ///   - repo: The repository name.
    ///   - prNumber: The pull-request number.
    /// - Returns: An array of ``PRCheck`` values, one per status-check entry.
    ///   Returns an empty array when the PR has no checks.
    /// - Throws: ``GitHubCommandError`` when the command fails or the output
    ///   cannot be parsed.
    public func fetchChecks(
        owner: String,
        repo: String,
        prNumber: Int
    ) async throws -> [PRCheck] {
        let json = try await commandRunner.run([
            "pr", "view", "\(prNumber)",
            "--repo", "\(owner)/\(repo)",
            "--json", "statusCheckRollup",
        ])
        return try parseChecks(from: json)
    }

    // MARK: - Review threads

    /// Fetches the review threads for a pull request.
    ///
    /// Issues a GraphQL query via:
    /// ```
    /// gh api graphql -f query='...'
    /// ```
    ///
    /// - Parameters:
    ///   - owner: The repository owner.
    ///   - repo: The repository name.
    ///   - prNumber: The pull-request number.
    /// - Returns: An array of ``ReviewThread`` values.
    ///   Returns an empty array when the PR has no review threads.
    /// - Throws: ``GitHubCommandError`` when the command fails or the output
    ///   cannot be parsed.
    public func fetchReviewThreads(
        owner: String,
        repo: String,
        prNumber: Int
    ) async throws -> [ReviewThread] {
        let query = reviewThreadsQuery(owner: owner, repo: repo, prNumber: prNumber)
        let json = try await commandRunner.run([
            "api", "graphql",
            "-f", "query=\(query)",
        ])
        return try parseReviewThreads(from: json)
    }

    // MARK: - Review-thread writes

    /// Posts a reply to an existing review thread.
    ///
    /// Issues the `addPullRequestReviewThreadReply` GraphQL mutation via:
    /// ```
    /// gh api graphql -f query='...' -f threadId=... -f body=...
    /// ```
    /// Passing `threadId` and `body` as separate `-f` variables keeps arbitrary
    /// reply text out of the query string, so a body containing quotes, braces,
    /// or GraphQL syntax cannot break the request.
    ///
    /// - Parameters:
    ///   - threadID: The GitHub node ID of the review thread to reply to.
    ///   - body: The markdown body of the reply.
    /// - Throws: ``GitHubCommandError`` when the command fails.
    public func replyToReviewThread(threadID: String, body: String) async throws {
        let mutation = """
        mutation($threadId: ID!, $body: String!) {
          addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $threadId, body: $body }) {
            comment { id }
          }
        }
        """
        _ = try await commandRunner.run([
            "api", "graphql",
            "-f", "query=\(mutation)",
            "-f", "threadId=\(threadID)",
            "-f", "body=\(body)",
        ])
    }

    /// Marks a review thread as resolved.
    ///
    /// Issues the `resolveReviewThread` GraphQL mutation via:
    /// ```
    /// gh api graphql -f query='...' -f threadId=...
    /// ```
    ///
    /// - Parameter threadID: The GitHub node ID of the review thread to resolve.
    /// - Throws: ``GitHubCommandError`` when the command fails.
    public func resolveReviewThread(threadID: String) async throws {
        let mutation = """
        mutation($threadId: ID!) {
          resolveReviewThread(input: { threadId: $threadId }) {
            thread { id isResolved }
          }
        }
        """
        _ = try await commandRunner.run([
            "api", "graphql",
            "-f", "query=\(mutation)",
            "-f", "threadId=\(threadID)",
        ])
    }

    // MARK: - Private helpers

    private func reviewThreadsQuery(owner: String, repo: String, prNumber: Int) -> String {
        """
        {
          repository(owner: "\(owner)", name: "\(repo)") {
            pullRequest(number: \(prNumber)) {
              reviewThreads(first: 100) {
                nodes {
                  id
                  isResolved
                  isOutdated
                  path
                  comments(first: 50) {
                    nodes {
                      id
                      body
                      author { login }
                      url
                    }
                  }
                }
              }
            }
          }
        }
        """
    }
}
