import Foundation
import RegattaGitHub
@testable import RegattaFleet

/// A deterministic ``WorkerSpawning`` stub for reactor tests.
///
/// Implements both spawn surfaces of the unified seam: the ci-fix worker spawn
/// (#30) records every ``CIFixWorkerSpec`` and hands back a ``StubWorkerHandle``
/// with a fixed `producesFix` verdict; the review-thread worker spawn (#31)
/// records every ``ReviewThreadWorkRequest`` and returns a canned
/// ``ReviewThreadWorkResult`` (or throws). No process or pane is involved.
final class StubWorkerSpawner: WorkerSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var _spawned: [CIFixWorkerSpec] = []
    private var _requests: [ReviewThreadWorkRequest] = []
    private var _conversationRequests: [ConversationCommentWorkRequest] = []
    private var _reviewRequests: [ReviewSummaryWorkRequest] = []
    private let producesFix: Bool
    private let result: ReviewThreadWorkResult
    private let conversationResult: ConversationCommentWorkResult
    private let reviewResult: ReviewSummaryWorkResult
    private let error: (any Error)?
    private let conversationError: (any Error)?
    private let reviewError: (any Error)?

    /// - Parameters:
    ///   - producesFix: What each spawned ci-fix worker's `attemptFix()` returns.
    ///   - result: The canned review-thread work result.
    ///   - conversationResult: The canned conversation-comment work result.
    ///   - reviewResult: The canned review-summary work result.
    ///   - error: When non-nil, the review-thread ``spawnWorker(for:)`` throws
    ///     this instead.
    ///   - conversationError: When non-nil, the conversation-comment
    ///     ``spawnWorker(for:)`` throws this instead.
    ///   - reviewError: When non-nil, the review-summary ``spawnWorker(for:)``
    ///     throws this instead.
    init(
        producesFix: Bool = true,
        result: ReviewThreadWorkResult = .init(pushedCodeChange: true, replyBody: "Addressed.", shouldResolve: true),
        conversationResult: ConversationCommentWorkResult = .init(pushedCodeChange: true, replyBody: "Addressed."),
        reviewResult: ReviewSummaryWorkResult = .init(pushedCodeChange: true, replyBody: "Addressed."),
        error: (any Error)? = nil,
        conversationError: (any Error)? = nil,
        reviewError: (any Error)? = nil
    ) {
        self.producesFix = producesFix
        self.result = result
        self.conversationResult = conversationResult
        self.reviewResult = reviewResult
        self.error = error
        self.conversationError = conversationError
        self.reviewError = reviewError
    }

    // MARK: - ci-fix spawn (#30)

    /// Every spec passed to ``spawn(_:)``, in order.
    var spawned: [CIFixWorkerSpec] { lock.withLock { _spawned } }

    /// Number of times ``spawn(_:)`` was called.
    var spawnCount: Int { lock.withLock { _spawned.count + _requests.count } }

    func spawn(_ spec: CIFixWorkerSpec) async -> any CIFixWorkerHandle {
        lock.withLock { _spawned.append(spec) }
        return StubWorkerHandle(id: spec.id, producesFix: producesFix)
    }

    // MARK: - review-thread spawn (#31)

    /// Every review-thread request passed to ``spawnWorker(for:)``, in order.
    var requests: [ReviewThreadWorkRequest] { lock.withLock { _requests } }

    func spawnWorker(for request: ReviewThreadWorkRequest) async throws -> ReviewThreadWorkResult {
        lock.withLock { _requests.append(request) }
        if let error { throw error }
        return result
    }

    // MARK: - conversation-comment spawn

    /// Every conversation-comment request passed to ``spawnWorker(for:)``, in order.
    var conversationRequests: [ConversationCommentWorkRequest] { lock.withLock { _conversationRequests } }

    /// Number of conversation-comment workers spawned.
    var conversationSpawnCount: Int { lock.withLock { _conversationRequests.count } }

    func spawnWorker(for request: ConversationCommentWorkRequest) async throws -> ConversationCommentWorkResult {
        lock.withLock { _conversationRequests.append(request) }
        if let conversationError { throw conversationError }
        return conversationResult
    }

    // MARK: - review-summary spawn

    /// Every review-summary request passed to ``spawnWorker(for:)``, in order.
    var reviewRequests: [ReviewSummaryWorkRequest] { lock.withLock { _reviewRequests } }

    /// Number of review-summary workers spawned.
    var reviewSpawnCount: Int { lock.withLock { _reviewRequests.count } }

    func spawnWorker(for request: ReviewSummaryWorkRequest) async throws -> ReviewSummaryWorkResult {
        lock.withLock { _reviewRequests.append(request) }
        if let reviewError { throw reviewError }
        return reviewResult
    }
}

/// A worker handle whose ``attemptFix()`` always returns a fixed verdict.
final class StubWorkerHandle: CIFixWorkerHandle, @unchecked Sendable {
    let id: String
    private let producesFix: Bool

    init(id: String, producesFix: Bool) {
        self.id = id
        self.producesFix = producesFix
    }

    func attemptFix() async -> Bool { producesFix }
}
