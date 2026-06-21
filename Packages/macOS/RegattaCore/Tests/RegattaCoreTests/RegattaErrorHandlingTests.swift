import Testing
import Foundation
@testable import RegattaCore

/// Failure-mode behavior tests for the orchestrator (issue #35).
///
/// Drives the orchestrator against a real ``RegattaWorktreeManager`` (a fixture
/// git repo in a temp dir) plus a headless ``FakePaneBridge`` so the full
/// failure paths run on CI with no real agent process or Ghostty pane:
///
/// - **Worker crash:** a non-zero exit marks the worker ``WorkerStatus/failed``,
///   retains the output it produced, notifies the brain, and counts as a failed
///   iteration.
/// - **Worktree conflict:** a worktree collision parks the worker
///   ``WorkerStatus/blocked`` (not failed), losing no data, and still notifies
///   the brain — but does *not* count as a failed iteration.
@Suite("RegattaOrchestrator — error handling (#35)")
struct RegattaErrorHandlingTests {

    // MARK: - Fixtures

    private func makeFixtureRepo() throws -> URL {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-err-repo-\(UUID().uuidString)", isDirectory: true)
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
            throw NSError(domain: "RegattaErrorHandlingTests", code: Int(process.terminationStatus))
        }
    }

    private func makeBaseDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-err-base-\(UUID().uuidString)", isDirectory: true)
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

    /// Polls the orchestrator's worker snapshot (a finite read, not the infinite
    /// `updates()` stream) until `predicate` holds or `timeout` elapses.
    ///
    /// Polling a snapshot — rather than iterating `updates()` — means a state
    /// where the target status never arrives returns `nil` promptly instead of
    /// parking forever inside an `AsyncStream` `for await` that no cancellation can
    /// interrupt (the AsyncStream-hang class `TestTimeout` warns about). This keeps
    /// the two-commit red structure fail-fast on CI rather than hanging the
    /// 15-minute budget.
    private func waitForStatus(
        _ orchestrator: RegattaOrchestrator,
        id: UUID,
        timeout: Duration = .seconds(8),
        where predicate: @escaping @Sendable (WorkerStatus) -> Bool
    ) async -> Worker? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let snap = await orchestrator.workers()
            if let worker = snap.first(where: { $0.id == id }), predicate(worker.status) {
                return worker
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    // MARK: - Worker crash → failed, output retained, brain notified

    @Test("a crashed worker is marked failed with its output retained and the brain notified as a failed iteration")
    func crashRetainsOutputAndNotifiesBrain() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let bridge = FakePaneBridge(behavior: .controlled)
        let observer = RecordingWorkerObserver()
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: bridge,
            workerObserver: observer
        )

        let id = await orchestrator.spawnWorker(spec(repoURL: repo))

        // Wait until the worker is actually running before driving its output.
        _ = await waitForStatus(orchestrator, id: id) { $0 == .running }

        // The agent emits some work, then crashes with a non-zero exit.
        let handleID = await bridge.spawnedIDs[0]
        if let controller = await bridge.controller(for: handleID) {
            controller.emit(.stdout("working on it...\n"))
            controller.emit(.stderr("fatal: boom\n"))
            controller.finish(terminated: 7)
        }

        let failed = await waitForStatus(orchestrator, id: id) {
            if case .failed = $0 { return true } else { return false }
        }
        guard case .failed(let reason)? = failed?.status else {
            Issue.record("expected .failed; got \(String(describing: failed?.status))")
            return
        }
        #expect(reason.contains("7"))

        // The brain was notified (the orchestrator notifies on a detached task,
        // so poll for the arrival) with the retained output and failed-iteration
        // flag. Bounded so a regression that drops the notification fails fast.
        guard let completion = await observer.firstCompletion() else {
            Issue.record("brain was not notified of the crashed worker")
            return
        }
        let completions = await observer.completions
        #expect(completions.count == 1)
        #expect(completion.id == id)
        #expect(completion.isFailedIteration)
        #expect(completion.status.isFailure)
        // Output produced before the crash is retained, including the started
        // marker the bridge emits plus the agent's own stdout/stderr.
        #expect(completion.output.contains("working on it..."))
        #expect(completion.output.contains("fatal: boom"))
    }

    // MARK: - Worktree conflict → blocked (no data loss)

    @Test("a worktree conflict parks the worker as blocked, not failed, and is not a failed iteration")
    func worktreeConflictBlocks() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }

        let manager = RegattaWorktreeManager(baseDirectory: base)
        let observer = RecordingWorkerObserver()
        let orchestrator = RegattaOrchestrator(
            worktreeManager: manager,
            paneBridge: FakePaneBridge(behavior: .autoExit(0)),
            workerObserver: observer
        )

        // Pre-provision a worktree on the branch the orchestrator will try to use
        // for the worker, so `git worktree add -b <branch>` collides on the branch
        // name → a recoverable worktree conflict.
        let id = UUID()
        let branch = "regatta/worker-\(id.uuidString.prefix(8))"
        _ = try await manager.createWorktree(
            forWorker: "preexisting-\(id.uuidString)",
            repoURL: repo,
            branch: String(branch)
        )

        // Spawn a worker whose derived branch collides with the one above.
        // (The orchestrator derives the branch from the worker id, so we reuse it.)
        let collidingID = await orchestrator.spawnWorkerForTest(
            spec(repoURL: repo),
            forcedID: id
        )

        let blocked = await waitForStatus(orchestrator, id: collidingID) {
            if case .blocked = $0 { return true } else { return false }
        }
        guard case .blocked? = blocked?.status else {
            Issue.record("expected .blocked; got \(String(describing: blocked?.status))")
            return
        }
        // A blocked worker is still cancellable so the human can clear it.
        #expect(blocked?.status.isCancellable == true)

        // The brain is notified, but a blocked worker is NOT a failed iteration.
        guard let completion = await observer.firstCompletion() else {
            Issue.record("brain was not notified of the blocked worker")
            return
        }
        let completions = await observer.completions
        #expect(completions.count == 1)
        #expect(completion.isFailedIteration == false)
    }
}

/// A ``WorkerObserver`` test double recording every completion handed to it.
///
/// The orchestrator notifies the observer from a detached `Task`, so a test must
/// `await` ``firstCompletion()`` rather than read ``completions`` synchronously
/// right after seeing the terminal status — otherwise the notification may not
/// have arrived yet (the race that made the crash test flaky under parallel
/// load).
actor RecordingWorkerObserver: WorkerObserver {
    private(set) var completions: [WorkerCompletion] = []

    func workerDidComplete(_ completion: WorkerCompletion) async {
        completions.append(completion)
    }

    /// Polls for the first completion, returning `nil` if none arrives within
    /// `timeout`. Bounded so a state where the observer is never notified fails
    /// fast instead of parking forever.
    func firstCompletion(timeout: Duration = .seconds(5)) async -> WorkerCompletion? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let first = completions.first { return first }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return completions.first
    }
}
