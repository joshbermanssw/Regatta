/// A top-level conversation comment on a pull request — an "issue comment" in
/// GitHub's data model, distinct from an inline code-review comment.
///
/// Where ``ReviewComment`` lives inside a ``ReviewThread`` (anchored to a file
/// and line in the diff), a `PRConversationComment` is posted in the PR's main
/// conversation timeline. These are what people leave when they "comment on the
/// PR" without selecting code — the ARMADA-style trigger the shepherd reacts to.
///
/// Corresponds to a node returned by:
/// ```
/// gh api repos/{owner}/{repo}/issues/{number}/comments
/// ```
/// (a PR is an issue for the comments endpoint), shaped as:
/// ```json
/// { "id": 12345, "body": "...", "user": { "login": "..." },
///   "html_url": "...", "created_at": "2026-06-21T12:00:00Z" }
/// ```
public struct PRConversationComment: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// The stable GitHub identifier of the comment, as a string.
    ///
    /// The REST endpoint returns a numeric `id`; it is carried here as a string
    /// so it keys the handled-id set uniformly with the rest of the Fleet's
    /// string identities.
    public let id: String
    /// The comment body (markdown text).
    public let body: String
    /// The login of the GitHub user who wrote the comment.
    public let author: String
    /// The URL to view this comment on GitHub.
    public let url: String
    /// The ISO-8601 creation timestamp string, as returned by GitHub.
    public let createdAt: String

    /// Creates a `PRConversationComment`.
    public init(id: String, body: String, author: String, url: String, createdAt: String) {
        self.id = id
        self.body = body
        self.author = author
        self.url = url
        self.createdAt = createdAt
    }
}
