import Foundation
import RegattaGitHub
@testable import RegattaFleet

// `StubWorkerSpawner` (the unified ci-fix + review-thread spawn stub) lives in
// `StubWorkerSpawner.swift`.

/// A stub ``PullRequestWriting`` that records reply/resolve/comment calls.
final class StubPullRequestWriter: PullRequestWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _replies: [(threadID: String, body: String)] = []
    private var _resolved: [String] = []
    private var _conversationComments: [(prNumber: Int, body: String)] = []
    private let failResolve: Bool
    private let failConversationComment: Bool

    init(failResolve: Bool = false, failConversationComment: Bool = false) {
        self.failResolve = failResolve
        self.failConversationComment = failConversationComment
    }

    var replies: [(threadID: String, body: String)] { lock.withLock { _replies } }
    var resolvedThreadIDs: [String] { lock.withLock { _resolved } }
    /// Every conversation comment posted, in order.
    var conversationComments: [(prNumber: Int, body: String)] { lock.withLock { _conversationComments } }

    func replyToReviewThread(threadID: String, body: String) async throws {
        lock.withLock { _replies.append((threadID, body)) }
    }

    func resolveReviewThread(threadID: String) async throws {
        if failResolve { throw GitHubCommandError.timedOut }
        lock.withLock { _resolved.append(threadID) }
    }

    func postConversationComment(owner: String, repo: String, prNumber: Int, body: String) async throws {
        if failConversationComment { throw GitHubCommandError.timedOut }
        lock.withLock { _conversationComments.append((prNumber, body)) }
    }
}

/// A stub ``OutwardActionGate`` that records every authorisation request and
/// can deny by action kind.
final class StubGate: OutwardActionGate, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [OutwardAction] = []
    private let allow: Bool
    private let deny: (OutwardAction) -> Bool

    init(allow: Bool = true, deny: @escaping (OutwardAction) -> Bool = { _ in false }) {
        self.allow = allow
        self.deny = deny
    }

    var seenActions: [OutwardAction] { lock.withLock { _seen } }

    func authorize(_ action: OutwardAction, for pullRequest: PullRequestRef) async -> OutwardActionVerdict {
        lock.withLock { _seen.append(action) }
        if deny(action) { return .denied }
        return allow ? .allowed : .denied
    }
}

/// A stub ``ReviewThreadActivityLogging`` that captures the event sequence.
final class StubActivityLog: ReviewThreadActivityLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ReviewThreadActivity] = []

    var events: [ReviewThreadActivity] { lock.withLock { _events } }
    func events(forThread id: String) -> [ReviewThreadActivity] {
        lock.withLock { _events.filter { $0.threadID == id } }
    }

    func log(_ activity: ReviewThreadActivity) async {
        lock.withLock { _events.append(activity) }
    }
}

/// Shorthand to build an open, commented review thread.
func makeThread(_ id: String, resolved: Bool = false, outdated: Bool = false, comments: Int = 1) -> ReviewThread {
    ReviewThread(
        id: id,
        isResolved: resolved,
        isOutdated: outdated,
        path: "Sources/\(id).swift",
        comments: (0..<comments).map {
            ReviewComment(id: "\(id)-c\($0)", body: "please fix", author: "reviewer", url: "https://x/\(id)/\($0)")
        }
    )
}

/// Shorthand to build a `.watching` shepherd state carrying the given threads.
func makeState(_ pr: PullRequestRef, threads: [ReviewThread]) -> ShepherdState {
    ShepherdState(pullRequest: pr, phase: .watching, reviewThreads: threads)
}
