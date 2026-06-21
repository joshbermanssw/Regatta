/// A single comment within a review thread.
///
/// Corresponds to a node in the `comments` list of a GitHub review thread,
/// as returned by the GraphQL API via `gh api graphql`.
public struct ReviewComment: Sendable, Equatable, Hashable, Codable {
    /// The GitHub node ID of the comment.
    public let id: String
    /// The comment body (markdown text).
    public let body: String
    /// The login of the GitHub user who wrote the comment.
    public let author: String
    /// The URL to view this comment on GitHub.
    public let url: String

    /// Creates a `ReviewComment`.
    public init(id: String, body: String, author: String, url: String) {
        self.id = id
        self.body = body
        self.author = author
        self.url = url
    }
}

/// A review thread (inline code-review discussion) on a pull request.
///
/// Maps to entries in the `reviewThreads` connection returned by the GitHub
/// GraphQL API for a pull request.
///
/// Assumption: the review thread shape is fetched via a GraphQL query such as:
/// ```graphql
/// query { repository(owner: $owner, name: $name) {
///   pullRequest(number: $prNumber) {
///     reviewThreads(first: 100) {
///       nodes { id isResolved isOutdated path comments(first: 50) {
///         nodes { id body author { login } url }
///       }}
///     }
///   }
/// }}
/// ```
public struct ReviewThread: Sendable, Equatable, Hashable, Codable {
    /// The GitHub node ID of the thread.
    public let id: String
    /// Whether the thread has been marked as resolved.
    public let isResolved: Bool
    /// Whether the thread is outdated (the code it refers to has changed).
    public let isOutdated: Bool
    /// The file path in the repository that the thread comments on.
    public let path: String
    /// The comments in this thread, in chronological order.
    public let comments: [ReviewComment]

    /// Creates a `ReviewThread`.
    public init(
        id: String,
        isResolved: Bool,
        isOutdated: Bool,
        path: String,
        comments: [ReviewComment]
    ) {
        self.id = id
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.path = path
        self.comments = comments
    }
}
