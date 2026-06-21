import Foundation
import RegattaFleet
import os

/// The app-target ``ReviewThreadActivityLogging`` conformer.
///
/// Routes each review-thread activity event to a structured `Logger` so the
/// review-thread reactor's lifecycle (spawned worker, pushed change, posted
/// reply, resolved, suppressed-by-gate, failed) is observable in Console while
/// the live spawn path runs. The Fleet card's richer per-PR activity log remains
/// the user-facing surface; this is the orchestration-side trace.
///
/// ## Concurrency
/// `Sendable` value type; the underlying `Logger` is thread-safe.
struct RegattaReviewThreadActivityLogger: ReviewThreadActivityLogging {
    private let logger = Logger(subsystem: "com.regatta.fleet", category: "review-threads")

    /// Creates a logger.
    init() {}

    func log(_ activity: ReviewThreadActivity) async {
        logger.info(
            "\(activity.pullRequest.id, privacy: .public) thread \(activity.threadID, privacy: .public): \(String(describing: activity.event), privacy: .public)"
        )
    }
}
