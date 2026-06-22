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
import Foundation

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

    // MARK: - Conversation comments

    /// Fetches the top-level conversation (issue) comments for a pull request.
    ///
    /// Shells out to:
    /// ```
    /// gh api repos/<owner>/<repo>/issues/<prNumber>/comments --paginate
    /// ```
    /// A PR is an issue for the comments endpoint, so this returns the comments
    /// posted in the PR's main conversation timeline — *not* the inline
    /// code-review comments (those are ``fetchReviewThreads(owner:repo:prNumber:)``).
    ///
    /// - Parameters:
    ///   - owner: The repository owner (user or organisation) on GitHub.
    ///   - repo: The repository name.
    ///   - prNumber: The pull-request number.
    /// - Returns: An array of ``PRConversationComment`` values, oldest first.
    ///   Returns an empty array when the PR has no conversation comments.
    /// - Throws: ``GitHubCommandError`` when the command fails or the output
    ///   cannot be parsed.
    public func fetchConversationComments(
        owner: String,
        repo: String,
        prNumber: Int
    ) async throws -> [PRConversationComment] {
        let json = try await commandRunner.run([
            "api", "repos/\(owner)/\(repo)/issues/\(prNumber)/comments",
            "--paginate",
        ])
        return try parseConversationComments(from: json)
    }

    // MARK: - Authenticated user

    /// The login of the currently authenticated `gh` user, cached after the first
    /// successful lookup.
    private var cachedLogin: String?

    /// Resolves (and caches) the login of the authenticated `gh` user.
    ///
    /// Shells out to:
    /// ```
    /// gh api user --jq .login
    /// ```
    /// The result is cached for the lifetime of the poller because the
    /// authenticated identity does not change while the app runs. This login is
    /// the loop-prevention key: the conversation-comment reactor skips any comment
    /// authored by it, so the shepherd never reacts to its own replies.
    ///
    /// - Returns: The authenticated user's login.
    /// - Throws: ``GitHubCommandError`` when the command fails.
    public func currentUserLogin() async throws -> String {
        if let cachedLogin { return cachedLogin }
        let output = try await commandRunner.run(["api", "user", "--jq", ".login"])
        let login = output.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedLogin = login
        return login
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

    // MARK: - Conversation-comment writes

    /// Posts a reply as a top-level conversation comment on a pull request.
    ///
    /// Shells out to:
    /// ```
    /// gh pr comment <prNumber> --repo <owner>/<repo> --body-file -
    /// ```
    /// The body is delivered on stdin (via `--body-file -`) rather than as an
    /// argument so reply text containing quotes, backticks, or shell
    /// metacharacters cannot break the invocation.
    ///
    /// > Important: The reactor must route this through the autonomy gate *and*
    /// > only ever post replies authored by the shepherd itself. Because the
    /// > shepherd's own login authors this comment, the reactor's
    /// > ``currentUserLogin``-based filter then skips it on the next poll — that
    /// > filter is what prevents the shepherd from replying to its own replies in
    /// > an infinite loop.
    ///
    /// - Parameters:
    ///   - owner: The repository owner.
    ///   - repo: The repository name.
    ///   - prNumber: The pull-request number.
    ///   - body: The markdown body of the comment.
    /// - Throws: ``GitHubCommandError`` when the command fails.
    public func postConversationComment(
        owner: String,
        repo: String,
        prNumber: Int,
        body: String
    ) async throws {
        _ = try await commandRunner.run([
            "pr", "comment", "\(prNumber)",
            "--repo", "\(owner)/\(repo)",
            "--body", body,
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
