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
    private var _handles: [StubWorkerHandle] = []
    private var _requests: [ReviewThreadWorkRequest] = []
    private var _conversationRequests: [ConversationCommentWorkRequest] = []
    private var _reviewRequests: [ReviewSummaryWorkRequest] = []
    private let producesFix: Bool
    /// When non-nil, each spawned ci-fix handle plays this scripted per-call
    /// outcome sequence instead of the fixed `producesFix` verdict.
    private let ciFixOutcomes: [CIFixAttemptOutcome]?
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
        ciFixOutcomes: [CIFixAttemptOutcome]? = nil,
        result: ReviewThreadWorkResult = .init(pushedCodeChange: true, replyBody: "Addressed.", shouldResolve: true),
        conversationResult: ConversationCommentWorkResult = .init(pushedCodeChange: true, replyBody: "Addressed."),
        reviewResult: ReviewSummaryWorkResult = .init(pushedCodeChange: true, replyBody: "Addressed."),
        error: (any Error)? = nil,
        conversationError: (any Error)? = nil,
        reviewError: (any Error)? = nil
    ) {
        self.producesFix = producesFix
        self.ciFixOutcomes = ciFixOutcomes
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
        let handle = ciFixOutcomes.map { StubWorkerHandle(id: spec.id, outcomes: $0) }
            ?? StubWorkerHandle(id: spec.id, producesFix: producesFix)
        lock.withLock {
            _spawned.append(spec)
            _handles.append(handle)
        }
        return handle
    }

    /// The most recently spawned ci-fix handle, for asserting `attemptFix()` call
    /// counts (e.g. that a no-progress stop did not re-attempt the worker).
    var lastHandle: StubWorkerHandle? { lock.withLock { _handles.last } }

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

/// A worker handle whose ``attemptFix()`` returns a fixed verdict, or a scripted
/// per-call sequence (the last element repeats once the sequence is exhausted).
///
/// Records how many times ``attemptFix()`` was invoked so a test can assert the
/// loop did not re-attempt the worker after a no-progress or cancel stop.
final class StubWorkerHandle: CIFixWorkerHandle, @unchecked Sendable {
    let id: String
    private let outcomes: [CIFixAttemptOutcome]
    private let lock = NSLock()
    private var _attemptCount = 0

    init(id: String, producesFix: Bool) {
        self.id = id
        self.outcomes = [producesFix ? .produced : .noFix]
    }

    /// A scripted per-call outcome sequence. The last element repeats for any
    /// extra calls (so an over-eager loop that respawns would just keep getting
    /// the final verdict — the test asserts the call count instead).
    init(id: String, outcomes: [CIFixAttemptOutcome]) {
        precondition(!outcomes.isEmpty, "need at least one scripted outcome")
        self.id = id
        self.outcomes = outcomes
    }

    /// Number of times ``attemptFix()`` has been invoked on this handle.
    var attemptCount: Int { lock.withLock { _attemptCount } }

    func attemptFix() async -> CIFixAttemptOutcome {
        lock.withLock {
            let index = min(_attemptCount, outcomes.count - 1)
            _attemptCount += 1
            return outcomes[index]
        }
    }
}
