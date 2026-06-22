public import RegattaGitHub
import Foundation

/// A single logged event in the lifecycle of addressing one PR conversation
/// comment (ARMADA-style "comment on the PR → a worker addresses it").
///
/// The ``ConversationCommentReactor`` emits these as it spawns workers and
/// performs (or suppresses) outward actions, mirroring ``ReviewThreadActivity``
/// for the conversation-comment surface. Each event carries the PR and the
/// comment id it concerns so a UI or test can group activity by comment.
public struct ConversationCommentActivity: Sendable, Equatable {
    /// What happened.
    public enum Event: Sendable, Equatable {
        /// A previously unseen, non-self-authored comment was detected and a
        /// worker was spawned for it.
        case spawnedWorker
        /// The worker pushed a code change addressing the comment.
        case pushedCodeChange
        /// A reply was posted to the conversation.
        case postedReply(body: String)
        /// An outward action was suppressed by the autonomy gate (issue #32).
        case suppressedByGate(OutwardAction)
        /// Addressing the comment failed; it remains unhandled and may retry.
        case failed(reason: String)
    }

    /// The PR the comment belongs to.
    public let pullRequest: PullRequestRef
    /// The id of the conversation comment this event concerns.
    public let commentID: String
    /// The event that occurred.
    public let event: Event

    /// Creates an activity record.
    public init(pullRequest: PullRequestRef, commentID: String, event: Event) {
        self.pullRequest = pullRequest
        self.commentID = commentID
        self.event = event
    }
}

/// The injection seam for recording per-comment conversation activity.
///
/// Kept as a protocol so production can route to the app's structured log while
/// tests inject a recorder that captures the event sequence for assertion. The
/// reactor calls ``log(_:)`` from its actor context, so conformers must be
/// `Sendable`.
public protocol ConversationCommentActivityLogging: Sendable {
    /// Records one activity event.
    /// - Parameter activity: The event to record.
    func log(_ activity: ConversationCommentActivity) async
}
