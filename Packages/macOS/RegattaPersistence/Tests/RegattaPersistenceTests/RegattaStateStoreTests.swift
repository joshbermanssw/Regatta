import Foundation
import Testing
@testable import RegattaPersistence
import RegattaCore
import RegattaFleet

/// Tests that ``RegattaStateStore`` persists state to disk and a fresh store
/// instance loads it back — the core "survive a restart" behaviour.
@Suite struct RegattaStateStoreTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("regatta-state-tests-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    private func sampleSnapshot() -> RegattaStateSnapshot {
        let pr = PullRequestRef(owner: "o", repo: "r", number: 12)
        return RegattaStateSnapshot(
            workers: [
                WorkerSnapshot(id: UUID(), name: "w1", prompt: "do it", status: .running, providerID: .claudeCode),
            ],
            loops: [
                LoopSnapshot(
                    workerID: "w1",
                    state: RegattaLoopState(
                        configuration: RegattaLoopConfiguration(goal: "g", stopCondition: .iterations(3)),
                        status: .running,
                        history: []
                    )
                ),
            ],
            shepherds: [ShepherdState(pullRequest: pr, phase: .watching)],
            autonomyModes: [pr.id: .staged],
            worktrees: [
                WorktreeSnapshot(
                    workerID: "w1",
                    path: URL(fileURLWithPath: "/tmp/w1"),
                    branch: "b",
                    repoURL: URL(fileURLWithPath: "/repo")
                ),
            ]
        )
    }

    @Test func freshStoreIsEmpty() async throws {
        let dir = makeTempDir()
        let store = try RegattaStateStore(baseDirectory: dir)
        let snapshot = await store.currentSnapshot()
        #expect(snapshot == .empty)
    }

    @Test func savedStateSurvivesNewStoreInstance() async throws {
        let dir = makeTempDir()
        let original = sampleSnapshot()

        let writer = try RegattaStateStore(baseDirectory: dir)
        try await writer.save(original)

        // Simulate a relaunch: a brand-new store over the same directory.
        let reader = try RegattaStateStore(baseDirectory: dir)
        let restored = await reader.currentSnapshot()
        #expect(restored == original)
    }

    @Test func writesFileToExpectedPath() async throws {
        let dir = makeTempDir()
        let store = try RegattaStateStore(baseDirectory: dir)
        try await store.save(sampleSnapshot())
        let url = dir.appendingPathComponent("regatta-state.json")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func updateMutatesAndPersists() async throws {
        let dir = makeTempDir()
        let store = try RegattaStateStore(baseDirectory: dir)
        let id = UUID()
        try await store.update { snap in
            snap.workers.append(
                WorkerSnapshot(id: id, name: "added", prompt: "p", status: .queued, providerID: .gemini)
            )
        }
        let reader = try RegattaStateStore(baseDirectory: dir)
        let restored = await reader.currentSnapshot()
        #expect(restored.workers.count == 1)
        #expect(restored.workers.first?.id == id)
    }

    @Test func corruptFileLoadsAsEmpty() async throws {
        let dir = makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("regatta-state.json")
        try Data("{not valid json".utf8).write(to: url)
        // Init must not throw; a bad write can never wedge launch.
        let store = try RegattaStateStore(baseDirectory: dir)
        let snapshot = await store.currentSnapshot()
        #expect(snapshot == .empty)
    }
}
