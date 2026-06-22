/// A reviewer's *submitted review* on a pull request — the Approve / Request
/// changes / Comment action a reviewer takes, carrying the review **summary
/// body** they wrote when submitting it.
///
/// This is distinct from both inline ``ReviewThread`` comments (anchored to a
/// file/line) and top-level ``PRConversationComment`` issue comments. When a
/// reviewer clicks "Approve", "Request changes", or "Comment" in the GitHub
/// review UI, the text they type goes into a review's `body` — *not* into a
/// conversation comment — so a PR approved with a summary note produces only a
/// `PRReview`, which is why the shepherd must watch reviews separately.
///
/// Corresponds to an entry returned by:
/// ```
/// gh pr view <number> --repo <owner>/<repo> --json reviews
/// ```
/// shaped as:
/// ```json
/// { "id": "PRR_...", "author": { "login": "..." }, "state": "APPROVED",
///   "body": "...", "submittedAt": "2026-06-21T12:00:00Z" }
/// ```
public struct PRReview: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// The state of a submitted review.
    ///
    /// Mirrors GitHub's review-state vocabulary. Unknown/legacy states map to
    /// ``other`` so decoding never fails on a value GitHub adds later.
    public enum State: String, Sendable, Equatable, Hashable, Codable {
        /// The reviewer approved the pull request.
        case approved = "APPROVED"
        /// The reviewer requested changes.
        case changesRequested = "CHANGES_REQUESTED"
        /// The reviewer left a comment-only review (no approve/block verdict).
        case commented = "COMMENTED"
        /// The review was dismissed.
        case dismissed = "DISMISSED"
        /// A pending or unrecognised review state.
        case other = "OTHER"

        /// Decodes a raw GitHub state string, mapping anything unrecognised to
        /// ``other`` so a new GitHub state value never breaks the poll.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .other
        }
    }

    /// The stable GitHub identifier of the review, as a string.
    ///
    /// Used as the handled-id key by the review-summary reactor so each review is
    /// acted on at most once.
    public let id: String
    /// The login of the GitHub user who submitted the review.
    public let author: String
    /// The review verdict (approved / changes requested / commented / dismissed).
    public let state: State
    /// The review **summary body** (markdown text). Empty for a bare approval
    /// with no note.
    public let body: String
    /// The ISO-8601 submission timestamp string, as returned by GitHub. Empty
    /// when GitHub omits it (e.g. a pending review).
    public let submittedAt: String

    /// Creates a `PRReview`.
    public init(id: String, author: String, state: State, body: String, submittedAt: String) {
        self.id = id
        self.author = author
        self.state = state
        self.body = body
        self.submittedAt = submittedAt
    }
}
