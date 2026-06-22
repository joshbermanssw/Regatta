import Foundation
import RegattaGitHub
@testable import RegattaFleet

/// A stub ``ConversationCommentActivityLogging`` that captures the event
/// sequence.
final class StubConversationCommentActivityLog: ConversationCommentActivityLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ConversationCommentActivity] = []

    var events: [ConversationCommentActivity] { lock.withLock { _events } }
    func events(forComment id: String) -> [ConversationCommentActivity] {
        lock.withLock { _events.filter { $0.commentID == id } }
    }

    func log(_ activity: ConversationCommentActivity) async {
        lock.withLock { _events.append(activity) }
    }
}

/// Shorthand to build a top-level PR conversation comment.
func makeComment(
    _ id: String,
    author: String,
    body: String = "please address this"
) -> PRConversationComment {
    PRConversationComment(
        id: id,
        body: body,
        author: author,
        url: "https://github.com/joshbermanssw/regatta/pull/42#issuecomment-\(id)",
        createdAt: "2026-06-21T12:00:00Z"
    )
}

/// Shorthand to build a `.watching` shepherd state carrying the given
/// conversation comments.
func makeConvState(_ pr: PullRequestRef, comments: [PRConversationComment]) -> ShepherdState {
    ShepherdState(pullRequest: pr, phase: .watching, conversationComments: comments)
}
