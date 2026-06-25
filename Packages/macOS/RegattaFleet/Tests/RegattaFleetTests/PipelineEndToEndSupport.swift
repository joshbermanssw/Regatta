import Foundation
import RegattaGitHub
import RegattaCore
@testable import RegattaFleet

// MARK: - Git fixture

/// A real origin+checkout git fixture so the pipeline's push step has a genuine
/// remote to advance. The worker's worktree is branched off `checkout`; a
/// gate-approved push goes `checkout-worktree → origin`.
struct PipelineGitFixture {
    let root: URL
    let origin: URL
    let checkout: URL
    /// The PR head branch the worker pushes to (the checkout's current branch).
    let branch: String

    /// Builds a fixture: a non-bare `origin` repo with one commit on `main`
    /// (configured to accept pushes to the checked-out branch) plus a `checkout`
    /// cloned from it (so `origin` is a real remote).
    static func make() throws -> PipelineGitFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-e2e-\(UUID().uuidString)", isDirectory: true)
        let origin = root.appendingPathComponent("origin", isDirectory: true)
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)

        try runGit(origin, "init", "-b", "main")
        try runGit(origin, "config", "user.email", "regatta-test@example.com")
        try runGit(origin, "config", "user.name", "Regatta Test")
        // Allow pushing to the checked-out branch of this non-bare origin so the
        // pipeline's `git push origin HEAD:main` advances the readable tip.
        try runGit(origin, "config", "receive.denyCurrentBranch", "ignore")
        try "# fixture\n".write(to: origin.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(origin, "add", ".")
        try runGit(origin, "commit", "-m", "init")

        try runGit(root, "clone", origin.path, checkout.path)
        try runGit(checkout, "config", "user.email", "regatta-test@example.com")
        try runGit(checkout, "config", "user.name", "Regatta Test")

        return PipelineGitFixture(root: root, origin: origin, checkout: checkout, branch: "main")
    }

    /// The commit SHA at `branch`'s tip in `repo` (default `main`).
    func tipSHA(_ repo: URL, branch: String = "main") throws -> String {
        try Self.captureGit(repo, "rev-parse", branch).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    static func runGit(_ repo: URL, _ args: String...) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repo.path] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PipelineGitFixture", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed in \(repo.path)"]
            )
        }
        return process.terminationStatus
    }

    static func captureGit(_ repo: URL, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repo.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "PipelineGitFixture.capture", code: Int(process.terminationStatus))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Real git-push conformer (mirrors the app's RegattaGitWorktreePusher)

/// A real ``WorktreePushing`` that runs `git -C <worktree> push <remote>
/// HEAD:<branch>` — a genuine push into the fixture remote. Mirrors the app-layer
/// `RegattaGitWorktreePusher` so the gate-approved push is exercised for real.
struct TestGitWorktreePusher: WorktreePushing {
    let remote: String
    init(remote: String = "origin") { self.remote = remote }

    func push(worktreePath: URL, branch: String) async throws {
        try PipelineGitFixture.runGit(worktreePath, "push", remote, "HEAD:\(branch)")
    }
}

// MARK: - Fake-agent harness (a real scripted subprocess that commits)

/// Builds a fake-agent shell script the orchestrator launches as a **real**
/// subprocess in the worker's worktree (cwd). This is the fake-agent harness — a
/// scripted process, never `claude`.
enum FakeAgentScriptBuilder {
    /// - Parameters:
    ///   - commits: When `true`, the script writes a file and makes a real
    ///     `git commit`, so the real diff probe detects new local commits ("produced
    ///     a fix"). When `false`, it exits 0 without touching the worktree, so the
    ///     diff probe reports "no fix" (the no-progress case).
    ///   - marker: A unique token written into the committed file.
    /// - Returns: the on-disk script URL (caller removes it).
    static func write(commits: Bool, marker: String) throws -> URL {
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fake-agent-\(UUID().uuidString).sh")
        let body: String
        if commits {
            body = """
            #!/bin/bash
            set -e
            git config user.email "fake-agent@example.com"
            git config user.name "Fake Agent"
            echo "fix \(marker)" > "fix-\(marker).txt"
            git add -A
            git commit -m "ci-fix: \(marker)" >/dev/null 2>&1
            echo "committed \(marker)"
            exit 0
            """
        } else {
            body = """
            #!/bin/bash
            echo "ran but produced no fix \(marker)"
            exit 0
            """
        }
        try body.write(to: scriptURL, atomically: true, encoding: .utf8)
        return scriptURL
    }
}

// MARK: - LiveOrchestratorSpawner (real RegattaCore seams)

/// A faithful in-test ``WorkerSpawning`` over the **real** RegattaCore spawn seams
/// — the same `RegattaOrchestrator` + `ProcessPaneBridge` + `RegattaWorktreeManager`
/// + `RegattaGitDiffProbe` the app's `OrchestratorWorkerSpawner` wraps. It mirrors
/// that spawner's ci-fix logic: spawn a worker (scripted fake agent), await its
/// terminal status, then use the **real** diff probe to detect whether the agent
/// committed work, recording the worktree so the gate-routed push targets it.
///
/// Living in the test target (rather than reaching into the app target) keeps the
/// pipeline test runnable under `swift test`; it exercises the genuine orchestrator
/// → pane-bridge → subprocess → worktree → diff path, not a stub.
final class LiveOrchestratorSpawner: WorkerSpawning, @unchecked Sendable {
    private let orchestrator: RegattaOrchestrator
    private let repoURL: URL
    private let scriptPath: String
    private let diffProbe: any RegattaDiffProbing
    private let worktreeStore: CIFixWorktreeStore?
    private let workerRegistry: ShepherdWorkerRegistry?

    private let lock = NSLock()
    private var _spawnCount = 0
    private var _conversationSpawnCount = 0
    private var _threadSpawnCount = 0
    private var _reviewSpawnCount = 0
    /// Number of times ``spawn(_:)`` (the ci-fix path) was called.
    var spawnCount: Int { lock.withLock { _spawnCount } }
    /// Number of conversation-comment addressing workers spawned.
    var conversationSpawnCount: Int { lock.withLock { _conversationSpawnCount } }
    /// Number of review-thread addressing workers spawned.
    var threadSpawnCount: Int { lock.withLock { _threadSpawnCount } }
    /// Number of review-summary addressing workers spawned.
    var reviewSpawnCount: Int { lock.withLock { _reviewSpawnCount } }

    init(
        orchestrator: RegattaOrchestrator,
        repoURL: URL,
        scriptPath: String,
        diffProbe: any RegattaDiffProbing = RegattaGitDiffProbe(),
        worktreeStore: CIFixWorktreeStore? = nil,
        workerRegistry: ShepherdWorkerRegistry? = nil
    ) {
        self.orchestrator = orchestrator
        self.repoURL = repoURL
        self.scriptPath = scriptPath
        self.diffProbe = diffProbe
        self.worktreeStore = worktreeStore
        self.workerRegistry = workerRegistry
    }

    /// Builds the launch that runs the fake-agent script in the worktree (cwd),
    /// without appending the prompt (the script ignores it).
    private func fakeAgentLaunch() -> WorkerAgentLaunch {
        WorkerAgentLaunch(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptPath],
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory(),
                "TMPDIR": NSTemporaryDirectory(),
            ],
            appendPrompt: false
        )
    }

    // MARK: ci-fix spawn (the path the pipeline test exercises)

    func spawn(_ spec: CIFixWorkerSpec) async -> any CIFixWorkerHandle {
        lock.withLock { _spawnCount += 1 }
        return LiveCIFixWorkerHandle(
            id: spec.id,
            pullRequest: spec.pullRequest,
            orchestrator: orchestrator,
            repoURL: repoURL,
            launch: fakeAgentLaunch(),
            diffProbe: diffProbe,
            worktreeStore: worktreeStore,
            workerRegistry: workerRegistry
        )
    }

    // The review/conversation/review-summary spawn surfaces of WorkerSpawning are
    // not exercised by the ci-fix pipeline scenarios; they run the same fake agent
    // and report whether it produced work, mirroring the app spawner's shape.
    func spawnWorker(for request: ReviewThreadWorkRequest) async throws -> ReviewThreadWorkResult {
        lock.withLock { _threadSpawnCount += 1 }
        let pushed = await runOnceAndDetectWork(name: "thread \(request.thread.id)", for: request.pullRequest)
        return ReviewThreadWorkResult(
            pushedCodeChange: pushed,
            replyBody: pushed ? "Addressed in a follow-up commit." : nil,
            shouldResolve: true
        )
    }

    func spawnWorker(for request: ConversationCommentWorkRequest) async throws -> ConversationCommentWorkResult {
        lock.withLock { _conversationSpawnCount += 1 }
        let pushed = await runOnceAndDetectWork(name: "comment \(request.comment.id)", for: request.pullRequest)
        return ConversationCommentWorkResult(
            pushedCodeChange: pushed,
            replyBody: "Addressed in a follow-up commit."
        )
    }

    func spawnWorker(for request: ReviewSummaryWorkRequest) async throws -> ReviewSummaryWorkResult {
        lock.withLock { _reviewSpawnCount += 1 }
        let pushed = await runOnceAndDetectWork(name: "review \(request.review.id)", for: request.pullRequest)
        return ReviewSummaryWorkResult(
            pushedCodeChange: pushed,
            replyBody: pushed ? "Addressed in a follow-up commit." : nil
        )
    }

    /// Spawns one worker, awaits terminal, and reports via the real diff probe
    /// whether it produced work. Shared by the addressing spawn surfaces. When the
    /// worker produced work it **records the worktree** into the shared store
    /// (keyed by PR) so the gate-routed push resolves it — mirroring the app
    /// spawner's addressing path (C1: addressing pushes need a recorded worktree).
    private func runOnceAndDetectWork(name: String, for pr: PullRequestRef) async -> Bool {
        let spec = WorkerSpec(name: name, prompt: "", repoURL: repoURL, agentLaunch: fakeAgentLaunch(), providerID: .claudeCode)
        let id = await orchestrator.spawnWorker(spec)
        await workerRegistry?.record(id, for: pr)
        let terminal = await orchestrator.awaitTerminal(id)
        await workerRegistry?.clear(id, for: pr)
        guard terminal?.status == .done,
              let worktree = await orchestrator.worktree(for: id) else { return false }
        let produced = (try? await diffProbe.hasProducedWork(at: worktree.path)) ?? false
        if produced {
            await worktreeStore?.record(worktree.path, for: pr)
        }
        return produced
    }
}

/// A ``CIFixWorkerHandle`` backed by the real orchestrator, mirroring the app's
/// `OrchestratorCIFixWorkerHandle`: each `attemptFix()` spawns one fresh worker
/// (the scripted fake agent) in a real worktree, awaits terminal, and reports
/// whether the agent committed work using the **real** diff probe — recording the
/// worktree so the gate-routed push targets exactly those commits.
final class LiveCIFixWorkerHandle: CIFixWorkerHandle, @unchecked Sendable {
    let id: String
    private let pullRequest: PullRequestRef
    private let orchestrator: RegattaOrchestrator
    private let repoURL: URL
    private let launch: WorkerAgentLaunch
    private let diffProbe: any RegattaDiffProbing
    private let worktreeStore: CIFixWorktreeStore?
    private let workerRegistry: ShepherdWorkerRegistry?

    init(
        id: String,
        pullRequest: PullRequestRef,
        orchestrator: RegattaOrchestrator,
        repoURL: URL,
        launch: WorkerAgentLaunch,
        diffProbe: any RegattaDiffProbing,
        worktreeStore: CIFixWorktreeStore?,
        workerRegistry: ShepherdWorkerRegistry?
    ) {
        self.id = id
        self.pullRequest = pullRequest
        self.orchestrator = orchestrator
        self.repoURL = repoURL
        self.launch = launch
        self.diffProbe = diffProbe
        self.worktreeStore = worktreeStore
        self.workerRegistry = workerRegistry
    }

    func attemptFix() async -> CIFixAttemptOutcome {
        let spec = WorkerSpec(
            name: "ci-fix \(pullRequest.repoSlug)#\(pullRequest.number)",
            prompt: "",
            repoURL: repoURL,
            agentLaunch: launch,
            providerID: .claudeCode
        )
        let workerID = await orchestrator.spawnWorker(spec)
        await workerRegistry?.record(workerID, for: pullRequest)
        let terminal = await orchestrator.awaitTerminal(workerID)
        await workerRegistry?.clear(workerID, for: pullRequest)

        switch terminal?.status {
        case .cancelled:
            return .cancelled
        case .done:
            guard let worktree = await orchestrator.worktree(for: workerID) else { return .noFix }
            let produced = (try? await diffProbe.hasProducedWork(at: worktree.path)) ?? false
            if produced {
                await worktreeStore?.record(worktree.path, for: pullRequest)
            }
            return produced ? .produced : .noFix
        default:
            return .noFix
        }
    }
}

// MARK: - PipelineEnv (one-stop real wiring per scenario)

/// Bundles the per-scenario real wiring: a git fixture, a fake-agent script, and a
/// real `RegattaOrchestrator` over a real `ProcessPaneBridge` + temp-dir worktree
/// manager. Builds the real ``AutonomyGate`` (with the real ``GitPushActionExecutor``
/// + a real git pusher) and a ``LiveOrchestratorSpawner`` on demand.
struct PipelineEnv {
    let fixture: PipelineGitFixture
    let base: URL
    let scriptURL: URL
    let orchestrator: RegattaOrchestrator

    init(agentCommits: Bool, marker: String) throws {
        self.fixture = try PipelineGitFixture.make()
        self.base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("regatta-e2e-base-\(UUID().uuidString)", isDirectory: true)
        self.scriptURL = try FakeAgentScriptBuilder.write(commits: agentCommits, marker: marker)
        self.orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(baseDirectory: base),
            paneBridge: ProcessPaneBridge()
        )
    }

    /// The real autonomy gate wired to the real push executor + a real `git push`
    /// into the fixture remote, resolving the worktree from the given store.
    func makeAutonomyGate(worktreeStore: CIFixWorktreeStore) -> AutonomyGate {
        let pushExecutor = GitPushActionExecutor(
            resolveWorktree: { action in await worktreeStore.worktree(for: action.pullRequest) },
            pusher: TestGitWorktreePusher()
        )
        return AutonomyGate(executor: pushExecutor)
    }

    /// A live spawner over this env's real orchestrator + fixture checkout + fake
    /// agent, recording into the given worktree store / registry.
    func makeSpawner(
        worktreeStore: CIFixWorktreeStore? = nil,
        registry: ShepherdWorkerRegistry? = nil
    ) -> LiveOrchestratorSpawner {
        LiveOrchestratorSpawner(
            orchestrator: orchestrator,
            repoURL: fixture.checkout,
            scriptPath: scriptURL.path,
            diffProbe: RegattaGitDiffProbe(),
            worktreeStore: worktreeStore,
            workerRegistry: registry
        )
    }

    func cleanup() {
        fixture.cleanup()
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.removeItem(at: scriptURL)
    }
}

// MARK: - Scripted poller (the only network-facing fake)

/// A scripted ``PullRequestPolling`` whose `fetchChecks` returns a sequence of
/// check snapshots (one per call, repeating the last) and whose comment / review /
/// thread fetches return caller-supplied canned snapshots. Self-login is fixed so
/// the shepherd's own / bot items can be filtered deterministically. Runs no `gh`
/// and touches no network.
final class SequencedChecksPoller: PullRequestPolling, @unchecked Sendable {
    enum CheckStep: Sendable {
        case green([String])
        case red([String])
        case pending([String])

        var checks: [PRCheck] {
            switch self {
            case .green(let names):
                return names.map { PRCheck(name: $0, status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil) }
            case .red(let names):
                return names.map { PRCheck(name: $0, status: "COMPLETED", conclusion: "FAILURE", detailsURL: nil) }
            case .pending(let names):
                return names.map { PRCheck(name: $0, status: "IN_PROGRESS", conclusion: nil, detailsURL: nil) }
            }
        }
    }

    private let lock = NSLock()
    private var steps: [CheckStep]
    private var index = 0
    private var _checkCalls = 0
    private let conversationComments: [PRConversationComment]
    private let reviewThreadsValue: [ReviewThread]
    private let reviewsValue: [PRReview]
    private let login: String

    init(
        _ steps: [CheckStep],
        conversationComments: [PRConversationComment] = [],
        reviewThreads: [ReviewThread] = [],
        reviews: [PRReview] = [],
        login: String = "shepherd-bot"
    ) {
        precondition(!steps.isEmpty, "need at least one check step")
        self.steps = steps
        self.conversationComments = conversationComments
        self.reviewThreadsValue = reviewThreads
        self.reviewsValue = reviews
        self.login = login
    }

    var checkCalls: Int { lock.withLock { _checkCalls } }

    func fetchChecks(owner: String, repo: String, prNumber: Int) async throws -> [PRCheck] {
        lock.withLock {
            _checkCalls += 1
            let step = steps[min(index, steps.count - 1)]
            if index < steps.count - 1 { index += 1 }
            return step.checks
        }
    }

    func fetchReviewThreads(owner: String, repo: String, prNumber: Int) async throws -> [ReviewThread] {
        reviewThreadsValue
    }

    func fetchConversationComments(owner: String, repo: String, prNumber: Int) async throws -> [PRConversationComment] {
        conversationComments
    }

    func fetchReviews(owner: String, repo: String, prNumber: Int) async throws -> [PRReview] {
        reviewsValue
    }

    func currentUserLogin() async throws -> String { login }
}

// MARK: - Recording write seam + activity log

/// A recording ``PullRequestWriting`` that captures conversation replies / thread
/// replies / resolves the reactors post, so a scenario can assert a write went out
/// (or did not) without touching `gh`.
final class RecordingPRWriter: PullRequestWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _threadReplies: [(threadID: String, body: String)] = []
    private var _resolvedThreads: [String] = []
    private var _conversationReplies: [String] = []

    var conversationReplies: [String] { lock.withLock { _conversationReplies } }
    var threadReplies: [(threadID: String, body: String)] { lock.withLock { _threadReplies } }
    var resolvedThreads: [String] { lock.withLock { _resolvedThreads } }

    func replyToReviewThread(threadID: String, body: String) async throws {
        lock.withLock { _threadReplies.append((threadID, body)) }
    }

    func resolveReviewThread(threadID: String) async throws {
        lock.withLock { _resolvedThreads.append(threadID) }
    }

    func postConversationComment(owner: String, repo: String, prNumber: Int, body: String) async throws {
        lock.withLock { _conversationReplies.append(body) }
    }
}

/// A no-op ``ConversationCommentActivityLogging`` for scenarios that do not assert
/// on the activity log.
struct NoopConversationCommentLog: ConversationCommentActivityLogging {
    func log(_ activity: ConversationCommentActivity) async {}
}

/// A no-op ``ReviewThreadActivityLogging`` for scenarios that do not assert on the
/// activity log.
struct NoopReviewThreadLog: ReviewThreadActivityLogging {
    func log(_ activity: ReviewThreadActivity) async {}
}

/// A no-op ``ReviewSummaryActivityLogging`` for scenarios that do not assert on the
/// activity log.
struct NoopReviewSummaryLog: ReviewSummaryActivityLogging {
    func log(_ activity: ReviewSummaryActivity) async {}
}
