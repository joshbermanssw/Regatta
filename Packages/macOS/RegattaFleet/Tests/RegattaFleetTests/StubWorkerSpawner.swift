import Foundation
@testable import RegattaFleet

/// A deterministic ``WorkerSpawning`` stub for CI-fix-reactor tests.
///
/// Records every spawned ``CIFixWorkerSpec`` and hands back a
/// ``StubWorkerHandle`` that reports a fixed `producesFix` verdict for every
/// ``CIFixWorkerHandle/attemptFix()`` call. No process or pane is involved.
final class StubWorkerSpawner: WorkerSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var _spawned: [CIFixWorkerSpec] = []
    private let producesFix: Bool

    /// - Parameter producesFix: What each spawned worker's `attemptFix()` returns.
    init(producesFix: Bool = true) {
        self.producesFix = producesFix
    }

    /// Every spec passed to ``spawn(_:)``, in order.
    var spawned: [CIFixWorkerSpec] { lock.withLock { _spawned } }

    /// Number of times ``spawn(_:)`` was called.
    var spawnCount: Int { lock.withLock { _spawned.count } }

    func spawn(_ spec: CIFixWorkerSpec) async -> any CIFixWorkerHandle {
        lock.withLock { _spawned.append(spec) }
        return StubWorkerHandle(id: spec.id, producesFix: producesFix)
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
