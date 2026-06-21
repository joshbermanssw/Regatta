import Foundation
import RegattaCore
import RegattaFleet
import RegattaGitHub

/// The production ``WorkerSpawning`` conformer that drives real agent workers
/// through the live ``RegattaOrchestrator`` (Seam A of the live-spawn wiring).
///
/// Both reactive layers spawn through this one seam:
/// - the CI-fix loop (#30) calls ``spawn(_:)`` to launch a `ci-fix` agent scoped
///   to a PR branch, and
/// - the review-thread handler (#31) calls ``spawnWorker(for:)`` to launch an
///   addressing agent scoped to one thread.
///
/// In both cases this builds a ``WorkerSpec``, hands it to the orchestrator (which
/// provisions an isolated worktree and launches the agent process via the
/// ``PaneBridge``), awaits the worker reaching a terminal status, and derives the
/// reactor-facing result from the worker's terminal status plus a `git diff` of
/// its worktree.
///
/// ## Repo resolution
/// The reactor seams carry only a ``PullRequestRef`` / branch, not a local
/// checkout path. The spawner resolves the on-disk repository for a PR through an
/// injected ``repoURLResolver`` closure so the composition root decides where the
/// agent runs (and tests inject a fixture repo).
///
/// ## Concurrency
/// `Sendable` value type; all dependencies are `Sendable` seams. Each spawn is
/// independent and drives the actor-isolated orchestrator only through `await`.
struct OrchestratorWorkerSpawner: WorkerSpawning {

    /// The live orchestrator that provisions worktrees and launches agents.
    private let orchestrator: RegattaOrchestrator

    /// Resolves the on-disk git repository a PR's worker should run against, or
    /// `nil` if it cannot be resolved (the spawn then surfaces as "no change").
    private let repoURLResolver: @Sendable (PullRequestRef) -> URL?

    /// Detects whether a finished worker left changes in its worktree.
    private let diffProbe: any RegattaDiffProbing

    /// The agent provider every spawned worker is launched with.
    private let provider: any AgentProvider

    /// Creates a spawner.
    ///
    /// - Parameters:
    ///   - orchestrator: The live orchestrator.
    ///   - repoURLResolver: Maps a PR to its on-disk repository. Defaults to the
    ///     process's current working directory's repo.
    ///   - diffProbe: The worktree change-detection seam. Defaults to
    ///     ``RegattaGitDiffProbe``.
    ///   - provider: The agent provider. Defaults to ``ClaudeCodeProvider``.
    init(
        orchestrator: RegattaOrchestrator,
        repoURLResolver: @escaping @Sendable (PullRequestRef) -> URL? = { _ in
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        },
        diffProbe: any RegattaDiffProbing = RegattaGitDiffProbe(),
        provider: any AgentProvider = ClaudeCodeProvider()
    ) {
        self.orchestrator = orchestrator
        self.repoURLResolver = repoURLResolver
        self.diffProbe = diffProbe
        self.provider = provider
    }

    // MARK: - WorkerSpawning

    func spawn(_ spec: CIFixWorkerSpec) async -> any CIFixWorkerHandle {
        OrchestratorCIFixWorkerHandle(
            id: spec.id,
            pullRequest: spec.pullRequest,
            branch: spec.branch,
            orchestrator: orchestrator,
            repoURL: repoURLResolver(spec.pullRequest),
            diffProbe: diffProbe,
            provider: provider
        )
    }

    func spawnWorker(for request: ReviewThreadWorkRequest) async throws -> ReviewThreadWorkResult {
        guard let repoURL = repoURLResolver(request.pullRequest) else {
            // No local checkout to run against; report "nothing done" so the
            // reactor leaves the thread open for a later retry.
            return ReviewThreadWorkResult(pushedCodeChange: false, replyBody: nil, shouldResolve: false)
        }

        let prompt = Self.reviewThreadPrompt(for: request)
        let workerSpec = WorkerSpec(
            name: "Address thread \(request.thread.id)",
            prompt: prompt,
            repoURL: repoURL,
            provider: provider
        )
        let id = await orchestrator.spawnWorker(workerSpec)
        let terminal = await orchestrator.awaitTerminal(id)

        guard terminal?.status == .done else {
            // Crash / block / cancel: not handled, retry next poll.
            return ReviewThreadWorkResult(pushedCodeChange: false, replyBody: nil, shouldResolve: false)
        }

        let pushed = await producedChanges(workerID: id)
        if pushed {
            return ReviewThreadWorkResult(
                pushedCodeChange: true,
                replyBody: String(
                    localized: "regatta.reviewThread.reply",
                    defaultValue: "Addressed in a follow-up commit."
                ),
                shouldResolve: true
            )
        }
        // The agent finished cleanly but produced no code change — treat it as
        // handled with no push and resolve the thread.
        return ReviewThreadWorkResult(pushedCodeChange: false, replyBody: nil, shouldResolve: true)
    }

    // MARK: - Helpers

    /// Whether the worker's worktree has uncommitted changes (its work product).
    private func producedChanges(workerID: UUID) async -> Bool {
        guard let worktree = await orchestrator.worktree(for: workerID) else { return false }
        return (try? await diffProbe.hasUncommittedChanges(at: worktree.path)) ?? false
    }

    /// Builds the addressing prompt from the thread's most recent comment.
    private static func reviewThreadPrompt(for request: ReviewThreadWorkRequest) -> String {
        let comment = request.thread.comments.last?.body ?? ""
        return """
        A reviewer left this comment on \(request.thread.path) in PR \
        \(request.pullRequest.repoSlug)#\(request.pullRequest.number):

        \(comment)

        Address the comment: make the code change it asks for, commit it, and push.
        """
    }
}

/// A ``CIFixWorkerHandle`` backed by the live ``RegattaOrchestrator``.
///
/// Each ``attemptFix()`` spawns one fresh agent worker scoped to the PR's repo,
/// awaits it reaching a terminal status, and reports whether it left changes in
/// its worktree (the "produced a fix worth pushing" signal the CI-fix loop wants).
struct OrchestratorCIFixWorkerHandle: CIFixWorkerHandle {
    let id: String
    private let pullRequest: PullRequestRef
    private let branch: String
    private let orchestrator: RegattaOrchestrator
    private let repoURL: URL?
    private let diffProbe: any RegattaDiffProbing
    private let provider: any AgentProvider

    init(
        id: String,
        pullRequest: PullRequestRef,
        branch: String,
        orchestrator: RegattaOrchestrator,
        repoURL: URL?,
        diffProbe: any RegattaDiffProbing,
        provider: any AgentProvider
    ) {
        self.id = id
        self.pullRequest = pullRequest
        self.branch = branch
        self.orchestrator = orchestrator
        self.repoURL = repoURL
        self.diffProbe = diffProbe
        self.provider = provider
    }

    func attemptFix() async -> Bool {
        guard let repoURL else { return false }
        let prompt = """
        CI is failing on PR \(pullRequest.repoSlug)#\(pullRequest.number) \
        (branch \(branch)). Make CI green: diagnose the failing checks, fix them, \
        commit, and push.
        """
        let spec = WorkerSpec(
            name: "ci-fix \(pullRequest.repoSlug)#\(pullRequest.number)",
            prompt: prompt,
            repoURL: repoURL,
            provider: provider
        )
        let workerID = await orchestrator.spawnWorker(spec)
        let terminal = await orchestrator.awaitTerminal(workerID)
        guard terminal?.status == .done else { return false }
        guard let worktree = await orchestrator.worktree(for: workerID) else { return false }
        return (try? await diffProbe.hasUncommittedChanges(at: worktree.path)) ?? false
    }
}
