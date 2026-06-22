import Foundation
import RegattaFleet
import os

/// The app-target ``ConversationCommentActivityLogging`` conformer.
///
/// Routes each conversation-comment activity event to a structured `Logger` so
/// the conversation-comment reactor's lifecycle (spawned worker, pushed change,
/// posted reply, suppressed-by-gate, failed) is observable in Console while the
/// live spawn path runs. The Fleet card's per-PR activity log remains the
/// user-facing surface; this is the orchestration-side trace.
///
/// ## Concurrency
/// `Sendable` value type; the underlying `Logger` is thread-safe.
struct RegattaConversationCommentActivityLogger: ConversationCommentActivityLogging {
    private let logger = Logger(subsystem: "com.regatta.fleet", category: "conversation-comments")

    /// Creates a logger.
    init() {}

    func log(_ activity: ConversationCommentActivity) async {
        logger.info(
            "\(activity.pullRequest.id, privacy: .public) comment \(activity.commentID, privacy: .public): \(String(describing: activity.event), privacy: .public)"
        )
    }
}
