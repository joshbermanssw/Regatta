public import RegattaGitHub
import Foundation

/// A single logged event in the lifecycle of addressing one review thread.
///
/// The reactor emits these as it spawns workers and performs (or suppresses)
/// outward actions, satisfying the issue-#31 requirement that per-thread
/// activity is logged. Each event carries the PR and thread it concerns so a UI
/// or test can group activity by thread.
public struct ReviewThreadActivity: Sendable, Equatable {
    /// What happened.
    public enum Event: Sendable, Equatable {
        /// A previously unseen, actionable thread was detected and a worker was
        /// spawned for it.
        case spawnedWorker
        /// The worker pushed a code change addressing the thread.
        case pushedCodeChange
        /// A reply was posted to the thread.
        case postedReply(body: String)
        /// The thread was resolved.
        case resolvedThread
        /// An outward action was suppressed by the autonomy gate (issue #32).
        case suppressedByGate(OutwardAction)
        /// Addressing the thread failed; it remains unhandled and may retry.
        case failed(reason: String)
    }

    /// The PR the thread belongs to.
    public let pullRequest: PullRequestRef
    /// The GitHub node ID of the thread this event concerns.
    public let threadID: String
    /// The event that occurred.
    public let event: Event

    /// Creates an activity record.
    public init(pullRequest: PullRequestRef, threadID: String, event: Event) {
        self.pullRequest = pullRequest
        self.threadID = threadID
        self.event = event
    }
}

/// The injection seam for recording per-thread activity.
///
/// Kept as a protocol so production can route to the app's debug event log
/// while tests inject a recorder that captures the sequence of events for
/// assertion. The reactor calls ``log(_:)`` from its actor context, so
/// conformers must be `Sendable`.
public protocol ReviewThreadActivityLogging: Sendable {
    /// Records one activity event.
    /// - Parameter activity: The event to record.
    func log(_ activity: ReviewThreadActivity) async
}
