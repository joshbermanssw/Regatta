import Foundation
import RegattaGitHub
@testable import RegattaFleet

/// A stub ``WorkerSpawning`` that records spawn requests and returns a canned
/// result (or throws). No agent or pane is launched.
final class StubWorkerSpawner: WorkerSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ReviewThreadWorkRequest] = []
    private let result: ReviewThreadWorkResult
    private let error: (any Error)?

    init(result: ReviewThreadWorkResult = .init(pushedCodeChange: true, replyBody: "Addressed.", shouldResolve: true),
         error: (any Error)? = nil) {
        self.result = result
        self.error = error
    }

    var requests: [ReviewThreadWorkRequest] { lock.withLock { _requests } }
    var spawnCount: Int { lock.withLock { _requests.count } }

    func spawnWorker(for request: ReviewThreadWorkRequest) async throws -> ReviewThreadWorkResult {
        lock.withLock { _requests.append(request) }
        if let error { throw error }
        return result
    }
}

/// A stub ``PullRequestWriting`` that records reply/resolve calls.
final class StubPullRequestWriter: PullRequestWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _replies: [(threadID: String, body: String)] = []
    private var _resolved: [String] = []
    private let failResolve: Bool

    init(failResolve: Bool = false) { self.failResolve = failResolve }

    var replies: [(threadID: String, body: String)] { lock.withLock { _replies } }
    var resolvedThreadIDs: [String] { lock.withLock { _resolved } }

    func replyToReviewThread(threadID: String, body: String) async throws {
        lock.withLock { _replies.append((threadID, body)) }
    }

    func resolveReviewThread(threadID: String) async throws {
        if failResolve { throw GitHubCommandError.timedOut }
        lock.withLock { _resolved.append(threadID) }
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

    func authorize(_ action: OutwardAction, for pullRequest: PullRequestRef) async -> Bool {
        lock.withLock { _seen.append(action) }
        if deny(action) { return false }
        return allow
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
