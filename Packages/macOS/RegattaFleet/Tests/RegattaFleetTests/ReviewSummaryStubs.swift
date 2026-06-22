import Foundation
import RegattaGitHub
@testable import RegattaFleet

/// A stub ``ReviewSummaryActivityLogging`` that captures the event sequence.
final class StubReviewSummaryActivityLog: ReviewSummaryActivityLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ReviewSummaryActivity] = []

    var events: [ReviewSummaryActivity] { lock.withLock { _events } }
    func events(forReview id: String) -> [ReviewSummaryActivity] {
        lock.withLock { _events.filter { $0.reviewID == id } }
    }

    func log(_ activity: ReviewSummaryActivity) async {
        lock.withLock { _events.append(activity) }
    }
}

/// Shorthand to build a submitted review.
func makeReview(
    _ id: String,
    author: String,
    state: PRReview.State = .commented,
    body: String = "please address the empty-input case before merging"
) -> PRReview {
    PRReview(
        id: id,
        author: author,
        state: state,
        body: body,
        submittedAt: "2026-06-21T12:00:00Z"
    )
}

/// Shorthand to build a `.watching` shepherd state carrying the given reviews.
func makeReviewState(_ pr: PullRequestRef, reviews: [PRReview]) -> ShepherdState {
    ShepherdState(pullRequest: pr, phase: .watching, reviews: reviews)
}
