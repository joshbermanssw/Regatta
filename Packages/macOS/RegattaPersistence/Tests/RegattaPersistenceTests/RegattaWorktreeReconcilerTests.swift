import Foundation
import Testing
@testable import RegattaPersistence

/// A deterministic ``WorktreeExistenceChecking`` that reports a fixed set of
/// paths as present, with no real filesystem access.
private struct StubExistenceChecker: WorktreeExistenceChecking {
    let present: Set<String>
    func worktreeExists(at url: URL) -> Bool { present.contains(url.path) }
}

/// Tests that worktree assignments are reconciled against disk: assignments whose
/// directory is gone are dropped, and the rest are kept.
@Suite struct RegattaWorktreeReconcilerTests {

    private func snap(_ worker: String, _ path: String) -> WorktreeSnapshot {
        WorktreeSnapshot(
            workerID: worker,
            path: URL(fileURLWithPath: path),
            branch: "regatta/\(worker)",
            repoURL: URL(fileURLWithPath: "/repo")
        )
    }

    @Test func keepsPresentDropsMissing() {
        let alive = snap("w1", "/tmp/regatta/w1")
        let gone = snap("w2", "/tmp/regatta/w2")
        let checker = StubExistenceChecker(present: [alive.path.path])
        let reconciler = RegattaWorktreeReconciler(existenceChecker: checker)

        let result = reconciler.reconcile([alive, gone])
        #expect(result.kept == [alive])
        #expect(result.dropped == [gone])
    }

    @Test func reconciledWorktreesRebuildsLiveRecords() {
        let alive = snap("w1", "/tmp/regatta/w1")
        let gone = snap("w2", "/tmp/regatta/w2")
        let checker = StubExistenceChecker(present: [alive.path.path])
        let reconciler = RegattaWorktreeReconciler(existenceChecker: checker)

        let worktrees = reconciler.reconciledWorktrees([alive, gone])
        #expect(worktrees.count == 1)
        #expect(worktrees.first?.workerID == "w1")
        #expect(worktrees.first?.path == alive.path)
    }

    @Test func reconcilesAgainstRealTempDirectory() throws {
        // A real on-disk reconcile: one directory created, one not.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("regatta-reconcile-\(UUID().uuidString)", isDirectory: true)
        let livePath = base.appendingPathComponent("w1", isDirectory: true)
        try FileManager.default.createDirectory(at: livePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let alive = WorktreeSnapshot(
            workerID: "w1", path: livePath, branch: "b", repoURL: URL(fileURLWithPath: "/repo")
        )
        let gone = WorktreeSnapshot(
            workerID: "w2",
            path: base.appendingPathComponent("w2", isDirectory: true),
            branch: "b",
            repoURL: URL(fileURLWithPath: "/repo")
        )

        let reconciler = RegattaWorktreeReconciler()  // real FileManager checker
        let result = reconciler.reconcile([alive, gone])
        #expect(result.kept == [alive])
        #expect(result.dropped == [gone])
    }
}
