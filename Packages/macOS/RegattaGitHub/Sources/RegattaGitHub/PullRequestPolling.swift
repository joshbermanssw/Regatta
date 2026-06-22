/// The injection seam for fetching a pull request's CI checks and review threads.
///
/// ``GitHubPoller`` is the production conformer (it shells out to `gh`). Higher
/// layers — such as a PR shepherd watcher in the Fleet — depend on
/// `any PullRequestPolling` rather than the concrete actor, so tests inject a
/// deterministic fake with no process spawn or network access.
///
/// ```swift
/// // Production
/// let poller: any PullRequestPolling = GitHubPoller()
///
/// // Tests
/// let poller: any PullRequestPolling = FakePullRequestPoller(...)
/// ```
public protocol PullRequestPolling: Sendable {
    /// Fetches the CI check statuses for a pull request.
    ///
    /// - Parameters:
    ///   - owner: The repository owner (user or organisation) on GitHub.
    ///   - repo: The repository name.
    ///   - prNumber: The pull-request number.
    /// - Returns: An array of ``PRCheck`` values, empty when the PR has no checks.
    /// - Throws: ``GitHubCommandError`` when the fetch fails or cannot be parsed.
    func fetchChecks(owner: String, repo: String, prNumber: Int) async throws -> [PRCheck]

    /// Fetches the review threads for a pull request.
    ///
    /// - Parameters:
    ///   - owner: The repository owner.
    ///   - repo: The repository name.
    ///   - prNumber: The pull-request number.
    /// - Returns: An array of ``ReviewThread`` values, empty when the PR has none.
    /// - Throws: ``GitHubCommandError`` when the fetch fails or cannot be parsed.
    func fetchReviewThreads(owner: String, repo: String, prNumber: Int) async throws -> [ReviewThread]

    /// Fetches the top-level conversation (issue) comments for a pull request.
    ///
    /// These are the comments posted in the PR's main conversation timeline, as
    /// opposed to inline code-review comments. They drive the conversation-comment
    /// reactor (ARMADA-style "comment on the PR and a worker addresses it").
    ///
    /// - Parameters:
    ///   - owner: The repository owner.
    ///   - repo: The repository name.
    ///   - prNumber: The pull-request number.
    /// - Returns: An array of ``PRConversationComment`` values, empty when the PR
    ///   has none.
    /// - Throws: ``GitHubCommandError`` when the fetch fails or cannot be parsed.
    func fetchConversationComments(owner: String, repo: String, prNumber: Int) async throws -> [PRConversationComment]

    /// Fetches the submitted reviews (Approve / Request changes / Comment) for a
    /// pull request, each carrying the reviewer's summary body.
    ///
    /// These drive the review-summary reactor: a PR approved with a note (or a
    /// changes-requested review) produces only a review, not a conversation
    /// comment, so the shepherd watches these separately.
    ///
    /// A default implementation returns `[]`, so a conformer that does not care
    /// about reviews (e.g. a check-only fake) need not implement it. The real
    /// ``GitHubPoller`` overrides it.
    ///
    /// - Parameters:
    ///   - owner: The repository owner.
    ///   - repo: The repository name.
    ///   - prNumber: The pull-request number.
    /// - Returns: An array of ``PRReview`` values, empty when the PR has none.
    /// - Throws: ``GitHubCommandError`` when the fetch fails or cannot be parsed.
    func fetchReviews(owner: String, repo: String, prNumber: Int) async throws -> [PRReview]

    /// The login of the currently authenticated `gh` user.
    ///
    /// The conversation-comment reactor uses this to skip comments the shepherd
    /// itself authored, so it never reacts to its own replies (loop prevention).
    /// Conformers should cache the value; it does not change while the app runs.
    ///
    /// - Returns: The authenticated user's login.
    /// - Throws: ``GitHubCommandError`` when the lookup fails.
    func currentUserLogin() async throws -> String
}

extension PullRequestPolling {
    /// Default: no reviews. Conformers that do not care about review summaries
    /// (e.g. check-only fakes) inherit this; ``GitHubPoller`` overrides it.
    public func fetchReviews(owner: String, repo: String, prNumber: Int) async throws -> [PRReview] {
        []
    }
}

/// ``GitHubPoller`` satisfies ``PullRequestPolling`` directly — its existing
/// `fetchChecks` and `fetchReviewThreads` methods match the protocol shape.
extension GitHubPoller: PullRequestPolling {}
