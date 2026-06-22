import Foundation
import Testing
import RegattaCore
import RegattaFleet
import RegattaGitHub

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// End-to-end tests for the live-spawn wiring (Seam A + Seam B): the production
/// ``OrchestratorWorkerSpawner`` and ``OrchestratorLoopEngineProvider`` driven
/// against a **real** ``RegattaOrchestrator`` backed by a headless fake
/// ``PaneBridge`` and a fixture git repo, so the full spawn → run → terminal →
/// diff path runs on CI with no real agent process.
@Suite("Orchestrator live-spawn conformers (Seam A + B)")
struct OrchestratorWorkerSpawnerTests {

    // MARK: - Fixtures

    private func makeFixtureRepo() throws -> URL {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-spawn-repo-\(UUID().uuidString)", isDirectory: true)
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
            throw NSError(domain: "OrchestratorWorkerSpawnerTests", code: Int(process.terminationStatus))
        }
    }

    private func makeBaseDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-spawn-base-\(UUID().uuidString)", isDirectory: true)
    }

    /// An orchestrator whose agent launch always exits 0 (so workers reach `.done`)
    /// and whose worktree manager provisions real worktrees off a fixture repo.
    private func makeOrchestrator(base: URL) -> RegattaOrchestrator {
        RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: TestEchoPaneBridge()
        )
    }

    /// A stub agent-CLI resolver returning a fixed dummy executable + environment.
    ///
    /// Tests that exercise the spawn path inject this so they do **not** depend on a
    /// real `claude`/`codex` being installed on the CI runner (the default resolver
    /// would throw "not found" there and the worker would never spawn). The fake
    /// ``PaneBridge`` never execs the path, so any value works.
    private let stubResolve: WorkerAgentExecutableResolving = { _ in
        WorkerAgentExecutableResolution(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        )
    }

    private func ref(_ number: Int = 1) -> PullRequestRef {
        PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: number)
    }

    // MARK: - Seam A: CIFix handle

    @Test("CIFix handle attemptFix resolves true when the agent leaves changes")
    func attemptFixDetectsChanges() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let orchestrator = makeOrchestrator(base: base)
        let spawner = OrchestratorWorkerSpawner(
            orchestrator: orchestrator,
            repoURLResolver: { _ in repo },
            diffProbe: TestDiffProbe(result: true),
            resolveExecutable: stubResolve
        )
        let handle = await spawner.spawn(CIFixWorkerSpec(pullRequest: ref(), branch: "main"))
        let produced = await handle.attemptFix()
        #expect(produced == true)
    }

    @Test("CIFix handle attemptFix resolves false when the agent leaves no changes")
    func attemptFixDetectsNoChanges() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let orchestrator = makeOrchestrator(base: base)
        let spawner = OrchestratorWorkerSpawner(
            orchestrator: orchestrator,
            repoURLResolver: { _ in repo },
            diffProbe: TestDiffProbe(result: false),
            resolveExecutable: stubResolve
        )
        let handle = await spawner.spawn(CIFixWorkerSpec(pullRequest: ref(), branch: "main"))
        let produced = await handle.attemptFix()
        #expect(produced == false)
    }

    // MARK: - Seam A: review-thread spawn

    @Test("review-thread spawn yields a pushed+resolve result when the agent changes code")
    func reviewThreadProducesResult() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let orchestrator = makeOrchestrator(base: base)
        let spawner = OrchestratorWorkerSpawner(
            orchestrator: orchestrator,
            repoURLResolver: { _ in repo },
            diffProbe: TestDiffProbe(result: true),
            resolveExecutable: stubResolve
        )
        let thread = ReviewThread(
            id: "T1", isResolved: false, isOutdated: false, path: "Sources/A.swift",
            comments: [ReviewComment(id: "c1", body: "please fix", author: "rev", url: "https://x")]
        )
        let result = try await spawner.spawnWorker(
            for: ReviewThreadWorkRequest(pullRequest: ref(), thread: thread)
        )
        #expect(result.pushedCodeChange == true)
        #expect(result.shouldResolve == true)
        #expect(result.replyBody != nil)
    }

    // MARK: - Bug 1: repo dir resolution from the handoff map

    /// The spawner resolves the PR's real on-disk checkout from the handoff map
    /// (the Fleet's ``PRRepositoryDirectoryStore``) — proving worktrees provision
    /// against the real repo and not the launched app's `/` working directory.
    @Test("review-thread spawn runs against the PR's recorded repo dir")
    func resolvesRepoDirFromHandoffMap() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let orchestrator = makeOrchestrator(base: base)

        // Record the PR → repo dir mapping exactly as a handoff would.
        let directories = PRRepositoryDirectoryStore()
        await directories.record(repo, for: ref(7))

        let spawner = OrchestratorWorkerSpawner(
            orchestrator: orchestrator,
            repoURLResolver: { pr in await directories.directory(for: pr) },
            diffProbe: TestDiffProbe(result: true),
            resolveExecutable: stubResolve
        )
        let thread = ReviewThread(
            id: "T1", isResolved: false, isOutdated: false, path: "Sources/A.swift",
            comments: [ReviewComment(id: "c1", body: "please fix", author: "rev", url: "https://x")]
        )
        let result = try await spawner.spawnWorker(
            for: ReviewThreadWorkRequest(pullRequest: ref(7), thread: thread)
        )
        // A worktree was provisioned off the real fixture repo and the agent ran
        // to completion (it could not have if the repo dir were `/`).
        #expect(result.pushedCodeChange == true)
    }

    /// A PR with no recorded checkout must NOT fall back to `/` (which yields the
    /// cryptic "target directory is not a git repository" error). The spawner
    /// reports "nothing done" so the reactor surfaces it cleanly instead.
    @Test("a PR with no recorded repo dir does not spawn against /")
    func unknownRepoDirFailsCleanly() async throws {
        let base = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let orchestrator = makeOrchestrator(base: base)

        let directories = PRRepositoryDirectoryStore() // empty — nothing recorded
        let spawner = OrchestratorWorkerSpawner(
            orchestrator: orchestrator,
            repoURLResolver: { pr in await directories.directory(for: pr) },
            diffProbe: TestDiffProbe(result: true)
        )
        let thread = ReviewThread(
            id: "T1", isResolved: false, isOutdated: false, path: "Sources/A.swift",
            comments: [ReviewComment(id: "c1", body: "please fix", author: "rev", url: "https://x")]
        )
        let result = try await spawner.spawnWorker(
            for: ReviewThreadWorkRequest(pullRequest: ref(99), thread: thread)
        )
        // No checkout ⇒ no work claimed; nothing pushed, nothing resolved.
        #expect(result.pushedCodeChange == false)
        #expect(result.shouldResolve == false)
    }

    /// A PR with no recorded checkout reports a clear, user-facing message
    /// (wired to a toast in production) rather than failing silently or in `/`.
    @Test("a PR with no recorded repo dir reports a clear missing-checkout message")
    func unknownRepoDirReportsToMissingHandler() async throws {
        let base = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let orchestrator = makeOrchestrator(base: base)

        let reported = MissingRepoRecorder()
        let spawner = OrchestratorWorkerSpawner(
            orchestrator: orchestrator,
            repoURLResolver: { _ in nil },
            diffProbe: TestDiffProbe(result: true),
            onMissingRepository: { pr in await reported.record(pr) }
        )
        let thread = ReviewThread(
            id: "T1", isResolved: false, isOutdated: false, path: "Sources/A.swift",
            comments: [ReviewComment(id: "c1", body: "please fix", author: "rev", url: "https://x")]
        )
        _ = try await spawner.spawnWorker(
            for: ReviewThreadWorkRequest(pullRequest: ref(5), thread: thread)
        )

        #expect(await reported.refs == [ref(5)])
    }

    // MARK: - Exit-127 fix: resolve the agent CLI's full path + complete env

    /// The spawner must launch the worker with the **resolved absolute executable**
    /// (not `/usr/bin/env`) so it does not depend on the GUI app's minimal `PATH` to
    /// find `claude` — the cause of the worker "exited with code 127" failure.
    @Test("review-thread spawn launches the resolved absolute executable, not /usr/bin/env")
    func resolvesAbsoluteExecutable() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let captor = CapturingPaneBridge()
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: captor
        )
        let resolved = URL(fileURLWithPath: "/Users/test/.local/bin/claude")
        let spawner = OrchestratorWorkerSpawner(
            orchestrator: orchestrator,
            repoURLResolver: { _ in repo },
            diffProbe: TestDiffProbe(result: true),
            resolveExecutable: { _ in
                WorkerAgentExecutableResolution(
                    executableURL: resolved,
                    environment: ["PATH": "/Users/test/.local/bin:/usr/bin", "HOME": "/Users/test"]
                )
            }
        )
        let thread = ReviewThread(
            id: "T1", isResolved: false, isOutdated: false, path: "Sources/A.swift",
            comments: [ReviewComment(id: "c1", body: "please fix", author: "rev", url: "https://x")]
        )
        _ = try await spawner.spawnWorker(
            for: ReviewThreadWorkRequest(pullRequest: ref(), thread: thread)
        )

        let spec = try #require(await captor.lastSpec)
        // Resolved absolute path, never /usr/bin/env.
        #expect(spec.executableURL == resolved)
        #expect(spec.executableURL.path != "/usr/bin/env")
        // The leading "claude" binary-name token is dropped now that the executable
        // is the resolved binary itself.
        #expect(spec.arguments.first == "-p")
        #expect(!spec.arguments.contains("claude"))
        // The prompt is still appended as the trailing argument.
        #expect(spec.arguments.last?.contains("please fix") == true)
        // The complete environment from the resolver is used (HOME preserved so
        // claude's keychain/OAuth auth keeps working).
        #expect(spec.environment["HOME"] == "/Users/test")
        #expect(spec.environment["PATH"] == "/Users/test/.local/bin:/usr/bin")
    }

    /// The CIFix handle must also launch the resolved absolute executable.
    @Test("CIFix attemptFix launches the resolved absolute executable")
    func ciFixResolvesAbsoluteExecutable() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let captor = CapturingPaneBridge()
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: captor
        )
        let resolved = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        let spawner = OrchestratorWorkerSpawner(
            orchestrator: orchestrator,
            repoURLResolver: { _ in repo },
            diffProbe: TestDiffProbe(result: true),
            resolveExecutable: { _ in
                WorkerAgentExecutableResolution(
                    executableURL: resolved,
                    environment: ["PATH": "/opt/homebrew/bin", "HOME": "/Users/test"]
                )
            }
        )
        let handle = await spawner.spawn(CIFixWorkerSpec(pullRequest: ref(), branch: "main"))
        _ = await handle.attemptFix()

        let spec = try #require(await captor.lastSpec)
        #expect(spec.executableURL == resolved)
        #expect(spec.arguments.first == "-p")
        #expect(!spec.arguments.contains("claude"))
    }

    /// When the agent CLI cannot be resolved, the spawner must surface a clear
    /// error and decline to spawn — never launch a worker that exits 127.
    @Test("an unresolvable agent CLI reports a clear error and does not spawn")
    func unresolvableAgentReportsAndDoesNotSpawn() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let captor = CapturingPaneBridge()
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: captor
        )
        let reported = UnresolvableAgentRecorder()
        let spawner = OrchestratorWorkerSpawner(
            orchestrator: orchestrator,
            repoURLResolver: { _ in repo },
            diffProbe: TestDiffProbe(result: true),
            resolveExecutable: { providerID in
                throw WorkerAgentExecutableResolutionError.notFound(
                    displayName: providerID.displayName, underlying: "no claude on PATH"
                )
            },
            onUnresolvableAgent: { error in await reported.record(error) }
        )
        let thread = ReviewThread(
            id: "T1", isResolved: false, isOutdated: false, path: "Sources/A.swift",
            comments: [ReviewComment(id: "c1", body: "please fix", author: "rev", url: "https://x")]
        )
        let result = try await spawner.spawnWorker(
            for: ReviewThreadWorkRequest(pullRequest: ref(), thread: thread)
        )

        // A clear error was reported (wired to a toast in production).
        #expect(await reported.count == 1)
        // No worker was spawned (no PaneSpec ever reached the bridge).
        #expect(await captor.lastSpec == nil)
        // Nothing claimed / resolved, so the reactor retries later.
        #expect(result.pushedCodeChange == false)
        #expect(result.shouldResolve == false)
    }

    /// Gemini has no agent-session equivalent the resolver can locate, so the
    /// default resolver surfaces a clear "unsupported" error rather than 127.
    @Test("the default resolver rejects an unsupported provider with a clear error")
    func defaultResolverRejectsGemini() {
        let resolve = WorkerAgentExecutableResolution.defaultResolver()
        #expect(throws: WorkerAgentExecutableResolutionError.self) {
            _ = try resolve(.gemini)
        }
    }

    /// The binary-name prefix strip is provider-aware and idempotent.
    @Test("binary-name prefix is stripped per provider and only when present")
    func stripsBinaryNamePrefix() {
        #expect(
            OrchestratorWorkerSpawner.strippingBinaryNamePrefix(
                ["claude", "-p", "--settings"], providerID: .claudeCode
            ) == ["-p", "--settings"]
        )
        #expect(
            OrchestratorWorkerSpawner.strippingBinaryNamePrefix(
                ["codex", "exec"], providerID: .codex
            ) == ["exec"]
        )
        // Idempotent: a launch already lacking the prefix is untouched.
        #expect(
            OrchestratorWorkerSpawner.strippingBinaryNamePrefix(
                ["-p", "--settings"], providerID: .claudeCode
            ) == ["-p", "--settings"]
        )
        // Only the matching provider's name is stripped.
        #expect(
            OrchestratorWorkerSpawner.strippingBinaryNamePrefix(
                ["codex", "exec"], providerID: .claudeCode
            ) == ["codex", "exec"]
        )
    }

    // MARK: - Reactor end-to-end (Seam A + the real CIFixReactor + a stub gate)

    @Test("CIFixReactor runs the real spawner to a green outcome when checks pass")
    func reactorEndToEndGreen() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let orchestrator = makeOrchestrator(base: base)
        let spawner = OrchestratorWorkerSpawner(
            orchestrator: orchestrator,
            repoURLResolver: { _ in repo },
            diffProbe: TestDiffProbe(result: true),
            resolveExecutable: stubResolve
        )
        // Poller reports all checks green so the loop condition stops on success.
        let poller = TestGreenPoller()
        let reactor = CIFixReactor(
            spawner: spawner,
            gate: AllowAllOutwardActionGate(),
            poller: poller,
            maxIterations: 3
        )
        let outcome = await reactor.runFixLoop(for: ref())
        #expect(outcome == .greenSuccess)
    }

    // MARK: - Seam B: loop engine provider runs a worker to terminal

    @Test("OrchestratorLoopEngineProvider builds an engine that runs the worker to a terminal state")
    func loopProviderRunsToTerminal() async throws {
        let repo = try makeFixtureRepo()
        let base = makeBaseDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: base)
        }
        let orchestrator = makeOrchestrator(base: base)
        let provider = OrchestratorLoopEngineProvider(
            orchestrator: orchestrator,
            repoURL: repo,
            diffProbe: TestDiffProbe(result: false) // no changes ⇒ succeeded ⇒ loop stops
        )
        let engine = provider.makeEngine(
            for: RegattaLoopConfiguration(
                goal: "make the tests pass",
                stopCondition: .iterations(3),
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 5, tokenBudget: 100_000)
            )
        )
        let finalState = await engine.run()
        #expect(finalState.status.isTerminal)
        #expect(!finalState.history.isEmpty)
    }
}

// MARK: - Test doubles (app-target accessible)

/// A headless ``PaneBridge`` that immediately runs the agent to a clean exit, so a
/// real ``RegattaOrchestrator`` drives a worker `.queued → .running → .done` with
/// no real subprocess. (RegattaCore's own `FakePaneBridge` is test-internal to
/// that package, so the app test target carries its own.)
private actor TestEchoPaneBridge: PaneBridge {
    private var running: Set<PaneHandle.ID> = []

    func spawn(_ spec: PaneSpec) async throws -> PaneHandle {
        let id = PaneHandle.ID()
        running.insert(id)
        let stream = AsyncStream<PaneOutputEvent> { continuation in
            continuation.yield(.stdout("started"))
            continuation.yield(.terminated(0))
            continuation.finish()
        }
        running.remove(id)
        return PaneHandle(id: id, output: stream)
    }

    func terminate(_ id: PaneHandle.ID) async throws {
        running.remove(id)
    }

    func isRunning(_ id: PaneHandle.ID) async -> Bool { running.contains(id) }
}

/// A headless ``PaneBridge`` that records the last ``PaneSpec`` it was handed (so a
/// test asserts the *resolved* executable, arguments, and environment reach the
/// spawn path) and immediately runs the agent to a clean exit.
private actor CapturingPaneBridge: PaneBridge {
    private(set) var lastSpec: PaneSpec?
    private var running: Set<PaneHandle.ID> = []

    func spawn(_ spec: PaneSpec) async throws -> PaneHandle {
        lastSpec = spec
        let id = PaneHandle.ID()
        running.insert(id)
        let stream = AsyncStream<PaneOutputEvent> { continuation in
            continuation.yield(.stdout("started"))
            continuation.yield(.terminated(0))
            continuation.finish()
        }
        running.remove(id)
        return PaneHandle(id: id, output: stream)
    }

    func terminate(_ id: PaneHandle.ID) async throws {
        running.remove(id)
    }

    func isRunning(_ id: PaneHandle.ID) async -> Bool { running.contains(id) }
}

/// Records every unresolvable-agent error the spawner reports, so a test asserts
/// the clear "CLI not found" report fires instead of a worker exiting 127.
private actor UnresolvableAgentRecorder {
    private(set) var count = 0
    func record(_ error: any Error) { count += 1 }
}

/// A ``RegattaDiffProbing`` returning a fixed answer, so a test pins whether a
/// finished worker is treated as "produced changes" without writing to the repo.
private struct TestDiffProbe: RegattaDiffProbing {
    let result: Bool
    func hasUncommittedChanges(at worktreePath: URL) async throws -> Bool { result }
}

/// Records every PR the spawner reports as having no local checkout, so a test
/// asserts the user-facing missing-checkout report fires (wired to a toast in
/// production) instead of a silent or `/`-rooted failure.
private actor MissingRepoRecorder {
    private(set) var refs: [PullRequestRef] = []
    func record(_ ref: PullRequestRef) { refs.append(ref) }
}

/// A ``PullRequestPolling`` that always reports a single green check, so the
/// CI-fix loop condition stops with success.
private struct TestGreenPoller: PullRequestPolling {
    func fetchChecks(owner: String, repo: String, prNumber: Int) async throws -> [PRCheck] {
        [PRCheck(name: "ci", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil)]
    }
    func fetchReviewThreads(owner: String, repo: String, prNumber: Int) async throws -> [ReviewThread] {
        []
    }
    func fetchConversationComments(owner: String, repo: String, prNumber: Int) async throws -> [PRConversationComment] {
        []
    }
    func currentUserLogin() async throws -> String { "shepherd-bot" }
}
