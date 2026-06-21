import Testing
import Foundation
@testable import RegattaCore

/// Behavior tests for the ``RegattaOrchestrator`` concurrency cap + queue
/// scheduler (issue #18).
///
/// These drive the orchestrator against a real ``RegattaWorktreeManager`` (a
/// fixture git repo in a temp dir) plus a headless ``FakePaneBridge`` in
/// `.controlled` mode, so workers stay alive ("running") until the test
/// deterministically completes them. That lets the test assert that excess
/// workers are held as ``WorkerStatus/queued`` and promoted as slots free —
/// with no real time, process, or Ghostty pane.
@Suite("RegattaOrchestrator concurrency cap + queue")
struct RegattaOrchestratorConcurrencyTests {

    // MARK: - Fixtures

    private func makeFixtureRepo() throws -> URL {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-cap-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try runShell("git", ["-C", temp.path, "init"])
        try runShell("git", ["-C", temp.path, "config", "user.email", "regatta-test@example.com"])
        try runShell("git", ["-C", temp.path, "config", "user.name", "Regatta Test"])
        try "# fixture\n".write(to: temp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runShell("git", ["-C", temp.path, "add", "."])
        try runShell("git", ["-C", temp.path, "commit", "-m", "init"])
        return temp
    }

    private func runShell(_ executable: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RegattaOrchestratorConcurrencyTests", code: Int(process.terminationStatus))
        }
    }

    private func makeBaseDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-cap-base-\(UUID().uuidString)", isDirectory: true)
    }

    private func spec(name: String, repoURL: URL) -> WorkerSpec {
        WorkerSpec(
            name: name,
            prompt: "do the thing",
            repoURL: repoURL,
            agentLaunch: WorkerAgentLaunch(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["agent"]
            )
        )
    }

    /// Waits (via `updates()`, no polling) until the Fleet snapshot satisfies
    /// `predicate`, then returns that snapshot. Returns the last snapshot if the
    /// stream finishes first.
    private func waitForSnapshot(
        _ orchestrator: RegattaOrchestrator,
        where predicate: @escaping @Sendable ([Worker]) -> Bool
    ) async -> [Worker] {
        var last: [Worker] = []
        for await snap in await orchestrator.updates() {
            last = snap
            if predicate(snap) { return snap }
        }
        return last
    }

    private func status(_ snapshot: [Worker], _ id: UUID) -> WorkerStatus? {
        snapshot.first(where: { $0.id == id })?.status
    }

    private func runningCount(_ snapshot: [Worker]) -> Int {
        snapshot.filter { $0.status == .running }.count
    }

    // MARK: - cap enforced

    @Test("with cap N, only N workers run and the rest stay queued")
    func capEnforced() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let bridge = FakePaneBridge(behavior: .controlled)
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: bridge,
            maxConcurrentWorkers: 2
        )

        let id1 = await orchestrator.spawnWorker(spec(name: "w1", repoURL: repo))
        let id2 = await orchestrator.spawnWorker(spec(name: "w2", repoURL: repo))
        let id3 = await orchestrator.spawnWorker(spec(name: "w3", repoURL: repo))

        // Exactly 2 reach running; the 3rd is held queued.
        let snap = await waitForSnapshot(orchestrator) { snap in
            self.runningCount(snap) == 2
        }
        #expect(runningCount(snap) == 2)
        #expect(status(snap, id3) == .queued)
        // Only 2 agents were ever launched while the cap is saturated.
        let spawned = await bridge.spawnedSpecs.count
        #expect(spawned == 2)
        _ = (id1, id2)
    }

    // MARK: - promotion on completion

    @Test("completing a running worker promotes the oldest queued worker")
    func promotionOnCompletion() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let bridge = FakePaneBridge(behavior: .controlled)
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: bridge,
            maxConcurrentWorkers: 1
        )

        let id1 = await orchestrator.spawnWorker(spec(name: "w1", repoURL: repo))
        let id2 = await orchestrator.spawnWorker(spec(name: "w2", repoURL: repo))

        // w1 runs, w2 queued.
        _ = await waitForSnapshot(orchestrator) { self.status($0, id1) == .running }
        let queuedSnap = await orchestrator.workers()
        #expect(status(queuedSnap, id2) == .queued)

        // Complete the first spawned handle (w1) cleanly.
        let finished = await bridge.finishControlledHandle(at: 0, code: 0)
        #expect(finished)

        // w2 is promoted to running automatically.
        let promoted = await waitForSnapshot(orchestrator) { self.status($0, id2) == .running }
        #expect(status(promoted, id2) == .running)
        #expect(status(promoted, id1) == .done)
    }

    // MARK: - promotion on cancellation

    @Test("cancelling a running worker promotes the oldest queued worker")
    func promotionOnCancellation() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let bridge = FakePaneBridge(behavior: .controlled)
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: bridge,
            maxConcurrentWorkers: 1
        )

        let id1 = await orchestrator.spawnWorker(spec(name: "w1", repoURL: repo))
        let id2 = await orchestrator.spawnWorker(spec(name: "w2", repoURL: repo))

        _ = await waitForSnapshot(orchestrator) { self.status($0, id1) == .running }

        try await orchestrator.cancelWorker(id1)

        let promoted = await waitForSnapshot(orchestrator) { self.status($0, id2) == .running }
        #expect(status(promoted, id2) == .running)
        #expect(status(promoted, id1) == .cancelled)
    }

    // MARK: - raising the cap re-evaluates the queue

    @Test("raising the cap promotes held workers immediately")
    func raisingCapPromotesQueued() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let bridge = FakePaneBridge(behavior: .controlled)
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: bridge,
            maxConcurrentWorkers: 1
        )

        let id1 = await orchestrator.spawnWorker(spec(name: "w1", repoURL: repo))
        let id2 = await orchestrator.spawnWorker(spec(name: "w2", repoURL: repo))
        let id3 = await orchestrator.spawnWorker(spec(name: "w3", repoURL: repo))

        _ = await waitForSnapshot(orchestrator) { self.runningCount($0) == 1 }

        // Raise the cap to 3 — all queued workers should start.
        await orchestrator.setMaxConcurrentWorkers(3)

        let snap = await waitForSnapshot(orchestrator) { self.runningCount($0) == 3 }
        #expect(status(snap, id1) == .running)
        #expect(status(snap, id2) == .running)
        #expect(status(snap, id3) == .running)
    }

    // MARK: - lowering the cap never kills running workers

    @Test("lowering the cap leaves running workers alone but holds new spawns")
    func loweringCapHoldsNewSpawns() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let bridge = FakePaneBridge(behavior: .controlled)
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: bridge,
            maxConcurrentWorkers: 2
        )

        let id1 = await orchestrator.spawnWorker(spec(name: "w1", repoURL: repo))
        let id2 = await orchestrator.spawnWorker(spec(name: "w2", repoURL: repo))
        _ = await waitForSnapshot(orchestrator) { self.runningCount($0) == 2 }

        // Lower the cap below the current running count.
        await orchestrator.setMaxConcurrentWorkers(1)

        // Both already-running workers keep running (no forced termination).
        let afterLower = await orchestrator.workers()
        #expect(status(afterLower, id1) == .running)
        #expect(status(afterLower, id2) == .running)

        // A new spawn is held queued because we are over the (lowered) cap.
        let id3 = await orchestrator.spawnWorker(spec(name: "w3", repoURL: repo))
        // Give the scheduler a chance; it must NOT launch w3.
        let snap = await orchestrator.workers()
        #expect(status(snap, id3) == .queued)

        // Completing both running workers frees one slot under the new cap of 1,
        // so exactly one of the freed slots promotes w3.
        await bridge.finishControlledHandle(at: 0, code: 0)
        await bridge.finishControlledHandle(at: 1, code: 0)
        let promoted = await waitForSnapshot(orchestrator) { self.status($0, id3) == .running }
        #expect(status(promoted, id3) == .running)
    }
}
