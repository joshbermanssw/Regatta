/// The injection seam for write operations against a pull request's review
/// threads.
///
/// Where ``PullRequestPolling`` covers read-only fetches, `PullRequestWriting`
/// covers the mutating side a PR shepherd needs once it decides to *act* on a
/// reviewer's comment: posting a reply tied to a thread and resolving that
/// thread.
///
/// ``GitHubPoller`` is the production conformer (it shells out to `gh`). Higher
/// layers depend on `any PullRequestWriting` so the reactive review-thread layer
/// can be tested with a deterministic fake that records calls instead of running
/// `gh`.
///
/// > Important: Conformers do **not** enforce autonomy policy. Whether an
/// > outward action is *allowed* to run is decided one layer up, behind the
/// > review-thread autonomy gate (issue #32). A `PullRequestWriting` call that
/// > reaches a conformer is a call that has already been authorised.
///
/// ```swift
/// // Production
/// let writer: any PullRequestWriting = GitHubPoller()
///
/// // Tests
/// let writer: any PullRequestWriting = FakePullRequestWriter()
/// ```
public protocol PullRequestWriting: Sendable {
    /// Posts a reply to an existing review thread.
    ///
    /// - Parameters:
    ///   - threadID: The GitHub node ID of the review thread to reply to
    ///     (``ReviewThread/id``).
    ///   - body: The markdown body of the reply.
    /// - Throws: ``GitHubCommandError`` when the underlying `gh` invocation
    ///   fails or its output cannot be parsed.
    func replyToReviewThread(threadID: String, body: String) async throws

    /// Marks a review thread as resolved.
    ///
    /// - Parameter threadID: The GitHub node ID of the review thread to resolve
    ///   (``ReviewThread/id``).
    /// - Throws: ``GitHubCommandError`` when the underlying `gh` invocation
    ///   fails or its output cannot be parsed.
    func resolveReviewThread(threadID: String) async throws

    /// Posts a reply as a top-level conversation comment on a pull request.
    ///
    /// Used by the conversation-comment reactor to answer a reviewer who left a
    /// general PR comment. Like the review-thread writes, the call reaching a
    /// conformer is one the autonomy gate has already authorised.
    ///
    /// - Parameters:
    ///   - owner: The repository owner.
    ///   - repo: The repository name.
    ///   - prNumber: The pull-request number.
    ///   - body: The markdown body of the comment.
    /// - Throws: ``GitHubCommandError`` when the underlying `gh` invocation fails.
    func postConversationComment(owner: String, repo: String, prNumber: Int, body: String) async throws
}

/// ``GitHubPoller`` satisfies ``PullRequestWriting`` directly — its
/// `replyToReviewThread` and `resolveReviewThread` methods match the protocol
/// shape, reusing the same injected ``GitHubCommandRunning``.
extension GitHubPoller: PullRequestWriting {}
