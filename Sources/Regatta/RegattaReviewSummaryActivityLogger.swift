import Foundation
import RegattaFleet
import os

/// The app-target ``ReviewSummaryActivityLogging`` conformer.
///
/// Routes each review-summary activity event to a structured `Logger` so the
/// review-summary reactor's lifecycle (spawned worker, pushed change, posted
/// reply, nothing-to-do, suppressed-by-gate, failed) is observable in Console
/// while the live spawn path runs. The Fleet card's per-PR activity log remains
/// the user-facing surface; this is the orchestration-side trace.
///
/// ## Concurrency
/// `Sendable` value type; the underlying `Logger` is thread-safe.
struct RegattaReviewSummaryActivityLogger: ReviewSummaryActivityLogging {
    private let logger = Logger(subsystem: "com.regatta.fleet", category: "review-summaries")

    /// Creates a logger.
    init() {}

    func log(_ activity: ReviewSummaryActivity) async {
        logger.info(
            "\(activity.pullRequest.id, privacy: .public) review \(activity.reviewID, privacy: .public): \(String(describing: activity.event), privacy: .public)"
        )
    }
}
