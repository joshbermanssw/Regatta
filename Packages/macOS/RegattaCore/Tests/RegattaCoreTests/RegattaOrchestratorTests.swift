import Testing
import Foundation
@testable import RegattaCore

/// Behavior tests for ``RegattaOrchestrator`` — the brain→Fleet spawn engine
/// (issue #16).
///
/// The orchestrator is driven against a real ``RegattaWorktreeManager`` (a fixture
/// git repo in a temp dir, so worktree provisioning is exercised end-to-end) plus
/// a headless ``FakePaneBridge`` standing in for the #14 Pane Bridge, so the full
/// spawn lifecycle runs on CI with no real agent process or Ghostty pane.
@Suite("RegattaOrchestrator")
struct RegattaOrchestratorTests {

    // MARK: - Fixtures

    /// Creates a throwaway git repo with an initial commit (HEAD needed for worktrees).
    private func makeFixtureRepo() throws -> URL {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-orch-repo-\(UUID().uuidString)", isDirectory: true)
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
            throw NSError(domain: "RegattaOrchestratorTests", code: Int(process.terminationStatus))
        }
    }

    private func makeBaseDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-orch-base-\(UUID().uuidString)", isDirectory: true)
    }

    private func spec(name: String = "Test worker", repoURL: URL) -> WorkerSpec {
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

    /// Waits (via the orchestrator's `updates()` stream, no polling) until a worker
    /// reaches a status satisfying `predicate`, then returns that snapshot.
    private func waitForStatus(
        _ orchestrator: RegattaOrchestrator,
        id: UUID,
        where predicate: @escaping @Sendable (WorkerStatus) -> Bool
    ) async -> Worker? {
        for await snap in await orchestrator.updates() {
            if let worker = snap.first(where: { $0.id == id }), predicate(worker.status) {
                return worker
            }
        }
        return nil
    }

    // MARK: - spawn → running → done

    @Test("spawnWorker provisions a worktree, launches the agent, and reaches .done on exit 0")
    func spawnReachesDone() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let worktreeManager = RegattaWorktreeManager(baseDirectory: base)
        let bridge = FakePaneBridge(behavior: .autoExit(0))
        let orchestrator = RegattaOrchestrator(worktreeManager: worktreeManager, paneBridge: bridge)

        let id = await orchestrator.spawnWorker(spec(repoURL: repo))

        // Worker shows up in the Fleet list with its name.
        let initial = await orchestrator.workers()
        #expect(initial.contains { $0.id == id && $0.name == "Test worker" })

        let done = await waitForStatus(orchestrator, id: id) { $0 == .done }
        #expect(done?.status == .done)

        // The agent was launched in the provisioned worktree directory.
        let specs = await bridge.spawnedSpecs
        #expect(specs.count == 1)
        #expect(specs.first?.workingDirectory.path.contains(base.lastPathComponent) == true)
        // Prompt is appended as the trailing argument.
        #expect(specs.first?.arguments.last == "do the thing")
    }

    // MARK: - nonzero exit → failed

    @Test("a non-zero agent exit transitions the worker to .failed")
    func nonZeroExitFails() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: FakePaneBridge(behavior: .autoExit(3))
        )

        let id = await orchestrator.spawnWorker(spec(repoURL: repo))
        let failed = await waitForStatus(orchestrator, id: id) { if case .failed = $0 { return true } else { return false } }
        guard case .failed(let reason)? = failed?.status else {
            Issue.record("expected .failed; got \(String(describing: failed?.status))")
            return
        }
        #expect(reason.contains("3"))
    }

    // MARK: - cancel a running worker

    @Test("cancelWorker terminates a running agent and marks the worker .cancelled")
    func cancelRunningWorker() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let bridge = FakePaneBridge(behavior: .controlled)
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: bridge
        )

        let id = await orchestrator.spawnWorker(spec(repoURL: repo))

        // Wait until it's actually running (process launched) before cancelling.
        _ = await waitForStatus(orchestrator, id: id) { $0 == .running }

        try await orchestrator.cancelWorker(id)

        let snap = await orchestrator.workers()
        #expect(snap.first(where: { $0.id == id })?.status == .cancelled)

        // The bridge was asked to terminate exactly the spawned handle.
        let terminated = await bridge.terminatedIDs
        #expect(terminated.count == 1)
    }

    // MARK: - provisioning failure → failed

    @Test("a worktree provisioning failure transitions the worker to .failed without spawning")
    func provisioningFailureFails() async throws {
        let base = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }

        // Point at a non-git directory so createWorktree throws .notAGitRepository.
        let notARepo = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-not-a-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notARepo) }

        let bridge = FakePaneBridge(behavior: .autoExit(0))
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: bridge
        )

        let id = await orchestrator.spawnWorker(spec(repoURL: notARepo))
        let failed = await waitForStatus(orchestrator, id: id) { if case .failed = $0 { return true } else { return false } }
        #expect({ if case .failed = failed?.status { return true } else { return false } }())

        // The agent must never be spawned when provisioning fails.
        let specs = await bridge.spawnedSpecs
        #expect(specs.isEmpty)
    }

    // MARK: - unknown worker cancel

    @Test("cancelWorker throws for an unknown worker id")
    func cancelUnknownThrows() async throws {
        let base = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: FakePaneBridge(behavior: .autoExit(0))
        )
        await #expect(throws: OrchestratorError.self) {
            try await orchestrator.cancelWorker(UUID())
        }
    }

    // MARK: - provider recorded + surfaced on the worker

    @Test("a worker spawned with the Codex provider records and surfaces that provider, launched via the same Pane Bridge path")
    func providerRecordedOnWorker() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let bridge = FakePaneBridge(behavior: .autoExit(0))
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: bridge
        )

        let codexSpec = WorkerSpec(
            name: "Codex worker",
            prompt: "do the thing",
            repoURL: repo,
            provider: CodexProvider()
        )
        let id = await orchestrator.spawnWorker(codexSpec)

        // Provider is surfaced on the worker snapshot immediately.
        let initial = await orchestrator.workers()
        #expect(initial.first(where: { $0.id == id })?.providerID == .codex)

        let done = await waitForStatus(orchestrator, id: id) { $0 == .done }
        #expect(done?.providerID == .codex)

        // Codex launched through the same Pane Bridge spawn path.
        let specs = await bridge.spawnedSpecs
        #expect(specs.count == 1)
        #expect(specs.first?.arguments.first == "codex")
        #expect(specs.first?.arguments.contains("exec") == true)
        #expect(specs.first?.arguments.last == "do the thing")
    }

    @Test("a worker spawned without an explicit provider defaults to Claude Code")
    func defaultProviderRecordedOnWorker() async throws {
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
        let initial = await orchestrator.workers()
        #expect(initial.first(where: { $0.id == id })?.providerID == .claudeCode)
    }

    // MARK: - multiple workers appear in spawn order

    @Test("multiple spawned workers appear in the Fleet snapshot in spawn order")
    func multipleWorkersOrdered() async throws {
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

        let id1 = await orchestrator.spawnWorker(spec(name: "first", repoURL: repo))
        let id2 = await orchestrator.spawnWorker(spec(name: "second", repoURL: repo))

        let snap = await orchestrator.workers()
        #expect(snap.map(\.id) == [id1, id2])
        #expect(snap.map(\.name) == ["first", "second"])
    }
}
