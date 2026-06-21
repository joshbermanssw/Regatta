import Testing
import Foundation
@testable import RegattaCore

/// Tests for the additive ``RegattaOrchestrator`` await-for-terminal and
/// worktree-accessor seams used by the live reactive spawner (Seam A).
///
/// Driven against a real ``RegattaWorktreeManager`` (a fixture git repo in a temp
/// dir) plus a headless ``FakePaneBridge``, so the spawn lifecycle runs on CI with
/// no real agent process or Ghostty pane.
@Suite("RegattaOrchestrator awaitTerminal + worktree accessor")
struct RegattaOrchestratorAwaitTerminalTests {

    // MARK: - Fixtures

    private func makeFixtureRepo() throws -> URL {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-await-repo-\(UUID().uuidString)", isDirectory: true)
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
            throw NSError(domain: "RegattaOrchestratorAwaitTerminalTests", code: Int(process.terminationStatus))
        }
    }

    private func makeBaseDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-await-base-\(UUID().uuidString)", isDirectory: true)
    }

    private func spec(repoURL: URL) -> WorkerSpec {
        WorkerSpec(
            name: "Await worker",
            prompt: "do the thing",
            repoURL: repoURL,
            agentLaunch: WorkerAgentLaunch(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["agent"]
            )
        )
    }

    // MARK: - awaitTerminal

    @Test("awaitTerminal resolves to .done when the worker exits 0")
    func awaitTerminalDone() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: FakePaneBridge(behavior: .autoExit(0))
        )
        let id = await orchestrator.spawnWorker(spec(repoURL: repo))
        let terminal = await orchestrator.awaitTerminal(id)
        #expect(terminal?.status == .done)
    }

    @Test("awaitTerminal resolves to .failed when the worker exits non-zero")
    func awaitTerminalFailed() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: FakePaneBridge(behavior: .autoExit(1))
        )
        let id = await orchestrator.spawnWorker(spec(repoURL: repo))
        let terminal = await orchestrator.awaitTerminal(id)
        #expect(terminal?.status.isFailure == true)
    }

    @Test("awaitTerminal returns nil for an unknown worker id")
    func awaitTerminalUnknown() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: FakePaneBridge(behavior: .autoExit(0))
        )
        let terminal = await orchestrator.awaitTerminal(UUID())
        #expect(terminal == nil)
    }

    // MARK: - worktree accessor

    @Test("worktree(for:) exposes the provisioned worktree for a completed worker")
    func worktreeExposed() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: FakePaneBridge(behavior: .autoExit(0))
        )
        let id = await orchestrator.spawnWorker(spec(repoURL: repo))
        _ = await orchestrator.awaitTerminal(id)
        let worktree = await orchestrator.worktree(for: id)
        #expect(worktree != nil)
        #expect(worktree?.repoURL == repo)
    }
}
