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
    /// `nil` if it cannot be resolved (the spawn then surfaces as "no change"
    /// instead of running an agent in the launched app's `/` working directory).
    private let repoURLResolver: @Sendable (PullRequestRef) async -> URL?

    /// Detects whether a finished worker left changes in its worktree.
    private let diffProbe: any RegattaDiffProbing

    /// The agent provider every spawned worker is launched with.
    private let provider: any AgentProvider

    /// Resolves the worker's agent CLI to a **full** executable path + complete
    /// environment so the spawned worker does not rely on the GUI app's minimal
    /// `PATH` (which omits `~/.local/bin` etc.) to find `claude` — the cause of the
    /// worker "exited with code 127" failure. Injected by the app layer so
    /// `RegattaCore` stays free of cmux's resolver; tests inject a stub.
    private let resolveExecutable: WorkerAgentExecutableResolving

    /// Surfaces a clear, user-facing report when a PR has no known local
    /// checkout, so the failure is a visible toast rather than a silent no-op or
    /// the cryptic "target directory is not a git repository" error. Defaults to
    /// a no-op so tests stay quiet; the composition root wires it to a toast.
    private let onMissingRepository: @Sendable (PullRequestRef) async -> Void

    /// Surfaces a clear, user-facing report when the worker's agent CLI cannot be
    /// resolved (e.g. `claude` is not installed), so the failure is a visible
    /// "Claude CLI not found" toast rather than a cryptic worker exit code 127.
    /// Defaults to a no-op so tests stay quiet; the composition root wires it to a
    /// toast.
    private let onUnresolvableAgent: @Sendable (any Error) async -> Void

    /// Records each ci-fix worker's worktree so the gate-routed push
    /// (``GitPushActionExecutor``) targets exactly the commits the agent made.
    /// Optional so review/conversation paths and tests can omit it.
    private let ciFixWorktreeStore: CIFixWorktreeStore?

    /// Tracks which workers each shepherd (PR) currently owns, so a shepherd
    /// dismiss can cascade-cancel them. Every spawn path records its worker here
    /// while it runs and clears it on termination. Optional so tests can omit it.
    private let workerRegistry: ShepherdWorkerRegistry?

    /// Creates a spawner.
    ///
    /// - Parameters:
    ///   - orchestrator: The live orchestrator.
    ///   - repoURLResolver: Maps a PR to its on-disk repository, captured from the
    ///     handoff that started the shepherd. Defaults to a resolver that yields
    ///     `nil` — there is **no** safe process-wide default (the app's working
    ///     directory is `/`), so an unwired spawner declines to run rather than
    ///     failing inside `/` with "the target directory is not a git repository".
    ///   - diffProbe: The worktree change-detection seam. Defaults to
    ///     ``RegattaGitDiffProbe``.
    ///   - provider: The agent provider. Defaults to ``ClaudeCodeProvider``.
    ///   - resolveExecutable: Resolves the worker's agent CLI to a full executable
    ///     path + complete environment. Defaults to the app-layer resolver backed by
    ///     ``AgentExecutableResolver``.
    ///   - onMissingRepository: Reports a PR with no known checkout to the user.
    ///     Defaults to a no-op.
    ///   - onUnresolvableAgent: Reports an unresolvable agent CLI to the user.
    ///     Defaults to a no-op.
    init(
        orchestrator: RegattaOrchestrator,
        repoURLResolver: @escaping @Sendable (PullRequestRef) async -> URL? = { _ in nil },
        diffProbe: any RegattaDiffProbing = RegattaGitDiffProbe(),
        provider: any AgentProvider = ClaudeCodeProvider(),
        resolveExecutable: @escaping WorkerAgentExecutableResolving = WorkerAgentExecutableResolution.defaultResolver(),
        onMissingRepository: @escaping @Sendable (PullRequestRef) async -> Void = { _ in },
        onUnresolvableAgent: @escaping @Sendable (any Error) async -> Void = { _ in },
        ciFixWorktreeStore: CIFixWorktreeStore? = nil,
        workerRegistry: ShepherdWorkerRegistry? = nil
    ) {
        self.orchestrator = orchestrator
        self.repoURLResolver = repoURLResolver
        self.diffProbe = diffProbe
        self.provider = provider
        self.resolveExecutable = resolveExecutable
        self.onMissingRepository = onMissingRepository
        self.onUnresolvableAgent = onUnresolvableAgent
        self.ciFixWorktreeStore = ciFixWorktreeStore
        self.workerRegistry = workerRegistry
    }

    // MARK: - WorkerSpawning

    func spawn(_ spec: CIFixWorkerSpec) async -> any CIFixWorkerHandle {
        let repoURL = await repoURLResolver(spec.pullRequest)
        if repoURL == nil {
            // No local checkout: surface it now so the user sees why the ci-fix
            // loop produces no work, instead of a silent or cryptic failure.
            await onMissingRepository(spec.pullRequest)
        }
        return OrchestratorCIFixWorkerHandle(
            id: spec.id,
            pullRequest: spec.pullRequest,
            branch: spec.branch,
            orchestrator: orchestrator,
            repoURL: repoURL,
            diffProbe: diffProbe,
            provider: provider,
            resolveExecutable: resolveExecutable,
            onUnresolvableAgent: onUnresolvableAgent,
            worktreeStore: ciFixWorktreeStore,
            workerRegistry: workerRegistry
        )
    }

    func spawnWorker(for request: ReviewThreadWorkRequest) async throws -> ReviewThreadWorkResult {
        guard let repoURL = await repoURLResolver(request.pullRequest) else {
            // No local checkout to run against; surface a clear toast and report
            // "nothing done" so the reactor leaves the thread open for a retry —
            // never run the agent in the launched app's `/` working directory.
            await onMissingRepository(request.pullRequest)
            return ReviewThreadWorkResult(pushedCodeChange: false, replyBody: nil, shouldResolve: false)
        }

        let prompt = Self.reviewThreadPrompt(for: request)
        guard let workerSpec = await makeResolvedSpec(
            name: "Address thread \(request.thread.id)",
            prompt: prompt,
            repoURL: repoURL
        ) else {
            // Agent CLI unresolvable: a clear toast already fired; leave the thread
            // open for a retry rather than spawning a worker that exits 127.
            return ReviewThreadWorkResult(pushedCodeChange: false, replyBody: nil, shouldResolve: false)
        }
        let (id, terminal) = await runRegistered(workerSpec, for: request.pullRequest)

        guard terminal?.status == .done else {
            // Crash / block / cancel: not handled, retry next poll.
            return ReviewThreadWorkResult(pushedCodeChange: false, replyBody: nil, shouldResolve: false)
        }

        let pushed = await producedChanges(workerID: id, for: request.pullRequest)
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

    func spawnWorker(for request: ConversationCommentWorkRequest) async throws -> ConversationCommentWorkResult {
        guard let repoURL = await repoURLResolver(request.pullRequest) else {
            // No local checkout to run against; surface a clear toast and report
            // "nothing done" so the reactor leaves the comment open for a retry.
            await onMissingRepository(request.pullRequest)
            return ConversationCommentWorkResult(pushedCodeChange: false, replyBody: nil)
        }

        let prompt = Self.conversationCommentPrompt(for: request)
        guard let workerSpec = await makeResolvedSpec(
            name: "Address comment \(request.comment.id)",
            prompt: prompt,
            repoURL: repoURL
        ) else {
            // Agent CLI unresolvable: a clear toast already fired; leave the comment
            // open for a retry rather than spawning a worker that exits 127.
            return ConversationCommentWorkResult(pushedCodeChange: false, replyBody: nil)
        }
        let (id, terminal) = await runRegistered(workerSpec, for: request.pullRequest)

        guard terminal?.status == .done else {
            // Crash / block / cancel: not handled, retry next poll.
            return ConversationCommentWorkResult(pushedCodeChange: false, replyBody: nil)
        }

        let pushed = await producedChanges(workerID: id, for: request.pullRequest)
        if pushed {
            return ConversationCommentWorkResult(
                pushedCodeChange: true,
                replyBody: String(
                    localized: "regatta.conversationComment.reply",
                    defaultValue: "Addressed in a follow-up commit."
                )
            )
        }
        // The agent finished cleanly but produced no code change — acknowledge
        // the comment with a short reply so the author knows it was seen.
        return ConversationCommentWorkResult(
            pushedCodeChange: false,
            replyBody: String(
                localized: "regatta.conversationComment.acknowledged",
                defaultValue: "Thanks — looked into this; no code change was needed."
            )
        )
    }

    func spawnWorker(for request: ReviewSummaryWorkRequest) async throws -> ReviewSummaryWorkResult {
        guard let repoURL = await repoURLResolver(request.pullRequest) else {
            // No local checkout to run against; surface a clear toast and report
            // "nothing done" so the reactor leaves the review open for a retry.
            await onMissingRepository(request.pullRequest)
            return ReviewSummaryWorkResult(pushedCodeChange: false, replyBody: nil)
        }

        let prompt = Self.reviewSummaryPrompt(for: request)
        guard let workerSpec = await makeResolvedSpec(
            name: "Address review \(request.review.id)",
            prompt: prompt,
            repoURL: repoURL
        ) else {
            // Agent CLI unresolvable: a clear toast already fired; leave the review
            // open for a retry rather than spawning a worker that exits 127.
            return ReviewSummaryWorkResult(pushedCodeChange: false, replyBody: nil)
        }
        let (id, terminal) = await runRegistered(workerSpec, for: request.pullRequest)

        guard terminal?.status == .done else {
            // Crash / block / cancel: not handled, retry next poll.
            return ReviewSummaryWorkResult(pushedCodeChange: false, replyBody: nil)
        }

        let pushed = await producedChanges(workerID: id, for: request.pullRequest)
        if pushed {
            return ReviewSummaryWorkResult(
                pushedCodeChange: true,
                replyBody: String(
                    localized: "regatta.review.reply",
                    defaultValue: "Addressed in a follow-up commit."
                )
            )
        }
        // The agent finished cleanly but produced no code change — e.g. a pure
        // approval or a comment that needed no action. Report "nothing done": no
        // reply is posted, matching the spec (a bare approval triggers no reply).
        return ReviewSummaryWorkResult(pushedCodeChange: false, replyBody: nil)
    }

    // MARK: - Helpers

    /// Builds a ``WorkerSpec`` whose agent launch uses the **resolved full
    /// executable path** and a **complete** environment, so the worker does not
    /// depend on the GUI app's minimal `PATH` to find its CLI (the exit-127 cause).
    ///
    /// Returns `nil` when the agent CLI cannot be resolved — having first surfaced a
    /// clear "CLI not found" report through ``onUnresolvableAgent`` — so the caller
    /// declines to spawn rather than launching a doomed worker that exits 127.
    private func makeResolvedSpec(name: String, prompt: String, repoURL: URL) async -> WorkerSpec? {
        do {
            let launch = try Self.resolvedLaunch(
                base: provider.makeLaunch(prompt: prompt),
                providerID: provider.id,
                resolve: resolveExecutable
            )
            return WorkerSpec(
                name: name,
                prompt: prompt,
                repoURL: repoURL,
                agentLaunch: launch,
                providerID: provider.id
            )
        } catch {
            await onUnresolvableAgent(error)
            return nil
        }
    }

    /// Rewrites a provider's PATH-relying ``WorkerAgentLaunch`` into one that runs
    /// the **resolved absolute executable** with a **complete** environment.
    ///
    /// Forwards to ``WorkerAgentExecutableResolution/resolvedLaunch(base:providerID:resolve:)``
    /// (which now lives in `RegattaCore` so it is exercised headlessly under
    /// `swift test`); kept here as a thin alias so this file's call sites and the
    /// `OrchestratorCIFixWorkerHandle` below read unchanged.
    ///
    /// - Throws: ``WorkerAgentExecutableResolutionError`` when resolution fails.
    static func resolvedLaunch(
        base: WorkerAgentLaunch,
        providerID: AgentProviderID,
        resolve: WorkerAgentExecutableResolving
    ) throws -> WorkerAgentLaunch {
        try WorkerAgentExecutableResolution.resolvedLaunch(
            base: base, providerID: providerID, resolve: resolve
        )
    }

    /// Spawns a worker for `spec`, registers it under `pullRequest` so a shepherd
    /// dismiss can cascade-cancel it, awaits its terminal status, and clears the
    /// ownership record. Returns `(id, terminal)` so the caller can inspect the
    /// worktree on `.done`. Shared by the review-thread / conversation-comment /
    /// review-summary spawn paths so all three honor the dismiss cascade.
    private func runRegistered(
        _ spec: WorkerSpec,
        for pullRequest: PullRequestRef
    ) async -> (id: UUID, terminal: Worker?) {
        let id = await orchestrator.spawnWorker(spec)
        await workerRegistry?.record(id, for: pullRequest)
        let terminal = await orchestrator.awaitTerminal(id)
        await workerRegistry?.clear(id, for: pullRequest)
        return (id, terminal)
    }

    /// Whether the worker produced work worth pushing — new local commits or
    /// uncommitted changes in its worktree.
    ///
    /// The autonomy gate (issue #32) owns the *push*: workers are prompted to fix
    /// and **commit locally, not push**, so the "produced changes" signal must
    /// catch a *clean-but-committed* worktree (the common case). Probing only for
    /// uncommitted changes would miss a worker that committed its fix and report a
    /// false "no fix" — the bug that made the loop respawn forever.
    ///
    /// When the worker produced work, this also **records its worktree** into the
    /// shared worktree store keyed by PR, so the gate-routed
    /// ``GitPushActionExecutor`` resolves exactly the commits the addressing agent
    /// made — the same machinery the ci-fix path uses. Without this the addressing
    /// push would have no worktree and the executor would throw `noWorktree`.
    private func producedChanges(workerID: UUID, for pullRequest: PullRequestRef) async -> Bool {
        guard let worktree = await orchestrator.worktree(for: workerID) else { return false }
        let produced = (try? await diffProbe.hasProducedWork(at: worktree.path)) ?? false
        if produced {
            await ciFixWorktreeStore?.record(worktree.path, for: pullRequest)
        }
        return produced
    }

    /// Builds the addressing prompt from the thread's most recent comment.
    private static func reviewThreadPrompt(for request: ReviewThreadWorkRequest) -> String {
        let comment = request.thread.comments.last?.body ?? ""
        return """
        A reviewer left this comment on \(request.thread.path) in PR \
        \(request.pullRequest.repoSlug)#\(request.pullRequest.number):

        \(comment)

        Address the comment: make the code change it asks for and commit it locally \
        in this worktree. Do NOT push — Regatta pushes through its autonomy gate \
        after you finish.
        """
    }

    /// Builds the addressing prompt from a conversation comment's body.
    private static func conversationCommentPrompt(for request: ConversationCommentWorkRequest) -> String {
        """
        Someone left this comment on the conversation of PR \
        \(request.pullRequest.repoSlug)#\(request.pullRequest.number) \
        (by @\(request.comment.author)):

        \(request.comment.body)

        Address the comment: if it asks for a code change, make it and commit it \
        locally in this worktree (do NOT push — Regatta pushes through its autonomy \
        gate after you finish). If it is a question, investigate and prepare a \
        concise answer.
        """
    }

    /// Builds the addressing prompt from a submitted review's summary body.
    private static func reviewSummaryPrompt(for request: ReviewSummaryWorkRequest) -> String {
        let verdict: String
        switch request.review.state {
        case .approved: verdict = "approved the PR"
        case .changesRequested: verdict = "requested changes"
        case .commented: verdict = "left a review comment"
        case .dismissed: verdict = "dismissed a review"
        case .other: verdict = "submitted a review"
        }
        return """
        @\(request.review.author) \(verdict) on PR \
        \(request.pullRequest.repoSlug)#\(request.pullRequest.number) with this \
        summary:

        \(request.review.body)

        Address the review: if it asks for a code change, make it and commit it \
        locally in this worktree (do NOT push — Regatta pushes through its autonomy \
        gate after you finish). If it is a question, investigate and prepare a \
        concise answer. If there is genuinely nothing to do (e.g. a plain approval \
        with no actionable request), make no change and post no reply.
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
    private let resolveExecutable: WorkerAgentExecutableResolving
    private let onUnresolvableAgent: @Sendable (any Error) async -> Void
    /// Records the worktree this worker committed into so the gate-routed push
    /// (``GitPushActionExecutor``) targets exactly those commits.
    private let worktreeStore: CIFixWorktreeStore?
    /// Tracks each iteration's worker under the PR so a shepherd dismiss can
    /// cascade-cancel the running ci-fix worker.
    private let workerRegistry: ShepherdWorkerRegistry?

    init(
        id: String,
        pullRequest: PullRequestRef,
        branch: String,
        orchestrator: RegattaOrchestrator,
        repoURL: URL?,
        diffProbe: any RegattaDiffProbing,
        provider: any AgentProvider,
        resolveExecutable: @escaping WorkerAgentExecutableResolving = WorkerAgentExecutableResolution.defaultResolver(),
        onUnresolvableAgent: @escaping @Sendable (any Error) async -> Void = { _ in },
        worktreeStore: CIFixWorktreeStore? = nil,
        workerRegistry: ShepherdWorkerRegistry? = nil
    ) {
        self.id = id
        self.pullRequest = pullRequest
        self.branch = branch
        self.orchestrator = orchestrator
        self.repoURL = repoURL
        self.diffProbe = diffProbe
        self.provider = provider
        self.resolveExecutable = resolveExecutable
        self.onUnresolvableAgent = onUnresolvableAgent
        self.worktreeStore = worktreeStore
        self.workerRegistry = workerRegistry
    }

    func attemptFix() async -> CIFixAttemptOutcome {
        guard let repoURL else { return .noFix }
        let prompt = """
        CI is failing on PR \(pullRequest.repoSlug)#\(pullRequest.number) \
        (branch \(branch)). Make CI green: diagnose the failing checks, fix them, \
        and commit your fix locally in this worktree. Do NOT push — Regatta pushes \
        through its autonomy gate after you finish.
        """
        let launch: WorkerAgentLaunch
        do {
            launch = try OrchestratorWorkerSpawner.resolvedLaunch(
                base: provider.makeLaunch(prompt: prompt),
                providerID: provider.id,
                resolve: resolveExecutable
            )
        } catch {
            // Agent CLI unresolvable: surface a clear toast and report "no fix"
            // rather than spawning a worker that exits 127.
            await onUnresolvableAgent(error)
            return .noFix
        }
        let spec = WorkerSpec(
            name: "ci-fix \(pullRequest.repoSlug)#\(pullRequest.number)",
            prompt: prompt,
            repoURL: repoURL,
            agentLaunch: launch,
            providerID: provider.id
        )
        let workerID = await orchestrator.spawnWorker(spec)
        // Record the live worker so a Fleet ✕ / dismiss cascade can cancel exactly
        // this PR's running ci-fix worker (shepherd→worker ownership).
        await workerRegistry?.record(workerID, for: pullRequest)
        let terminal = await orchestrator.awaitTerminal(workerID)
        await workerRegistry?.clear(workerID, for: pullRequest)

        switch terminal?.status {
        case .cancelled:
            // User ✕ (Fleet) or a shepherd-dismiss cascade marked the worker
            // cancelled. A cancel is a final STOP, never "ran, no fix → advance":
            // report `.cancelled` so the loop terminates instead of respawning.
            return .cancelled
        case .failed(let reason) where RegattaCancellationExit.isTerminationSignalFailure(reason):
            // A worker killed by a termination signal (SIGTERM/SIGKILL, exit 9/15
            // etc.) is a cancellation, not a self-inflicted failure that should
            // advance the loop — the SIGKILL-respawn the user dogfooded.
            return .cancelled
        case .done:
            guard let worktree = await orchestrator.worktree(for: workerID) else { return .noFix }
            // "Produced a fix" = new local commits OR uncommitted changes. The
            // worker is prompted to commit (not push) so a clean-but-committed
            // worktree is the common success case; probing only for uncommitted
            // changes would miss it and report a false "no fix", respawning the
            // loop forever.
            let produced = (try? await diffProbe.hasProducedWork(at: worktree.path)) ?? false
            if produced {
                // Record the worktree so the gate-routed push targets exactly these
                // commits. Regatta — not the agent — performs the push, preserving
                // the staged-approval autonomy gate.
                await worktreeStore?.record(worktree.path, for: pullRequest)
            }
            return produced ? .produced : .noFix
        default:
            // Any other non-done terminal (failed-on-purpose, blocked) is a
            // no-fix iteration; the loop's no-progress guard then stops it.
            return .noFix
        }
    }
}

// `RegattaCancellationExit` (the signal-kill classification both loop drivers use)
// now lives in `RegattaCore` so it can be exercised headlessly under `swift test`.
// This file's `OrchestratorCIFixWorkerHandle` and `OrchestratorLoopEngineProvider`
// continue to reach it through `import RegattaCore`.
