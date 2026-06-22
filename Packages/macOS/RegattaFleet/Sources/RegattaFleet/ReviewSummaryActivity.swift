public import RegattaGitHub
import Foundation

/// A single logged event in the lifecycle of addressing one reviewer's submitted
/// review (review summary) — the Approve / Request changes / Comment note a
/// reviewer left when submitting their review.
///
/// The ``ReviewSummaryReactor`` emits these as it spawns workers and performs (or
/// suppresses) outward actions, mirroring ``ReviewThreadActivity`` and
/// ``ConversationCommentActivity`` for the review-summary surface. Each event
/// carries the PR and the review id it concerns so a UI or test can group
/// activity by review.
public struct ReviewSummaryActivity: Sendable, Equatable {
    /// What happened.
    public enum Event: Sendable, Equatable {
        /// A previously unseen, actionable review was detected and a worker was
        /// spawned for it.
        case spawnedWorker
        /// The worker pushed a code change addressing the review.
        case pushedCodeChange
        /// A reply was posted to the PR conversation in response to the review.
        case postedReply(body: String)
        /// The worker determined there was nothing to do (e.g. a pure approval),
        /// so no reply was posted. The review is still marked handled.
        case nothingToDo
        /// An outward action was suppressed by the autonomy gate (issue #32).
        case suppressedByGate(OutwardAction)
        /// Addressing the review failed; it remains unhandled and may retry.
        case failed(reason: String)
    }

    /// The PR the review belongs to.
    public let pullRequest: PullRequestRef
    /// The id of the review this event concerns.
    public let reviewID: String
    /// The event that occurred.
    public let event: Event

    /// Creates an activity record.
    public init(pullRequest: PullRequestRef, reviewID: String, event: Event) {
        self.pullRequest = pullRequest
        self.reviewID = reviewID
        self.event = event
    }
}

/// The injection seam for recording per-review activity.
///
/// Kept as a protocol so production can route to the app's structured log while
/// tests inject a recorder that captures the event sequence for assertion. The
/// reactor calls ``log(_:)`` from its actor context, so conformers must be
/// `Sendable`.
public protocol ReviewSummaryActivityLogging: Sendable {
    /// Records one activity event.
    /// - Parameter activity: The event to record.
    func log(_ activity: ReviewSummaryActivity) async
}
