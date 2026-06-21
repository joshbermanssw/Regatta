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
    private let producesFix: Bool
    private let result: ReviewThreadWorkResult
    private let error: (any Error)?

    /// - Parameters:
    ///   - producesFix: What each spawned ci-fix worker's `attemptFix()` returns.
    ///   - result: The canned review-thread work result.
    ///   - error: When non-nil, ``spawnWorker(for:)`` throws this instead.
    init(
        producesFix: Bool = true,
        result: ReviewThreadWorkResult = .init(pushedCodeChange: true, replyBody: "Addressed.", shouldResolve: true),
        error: (any Error)? = nil
    ) {
        self.producesFix = producesFix
        self.result = result
        self.error = error
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
