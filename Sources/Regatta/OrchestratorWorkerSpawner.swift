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
        onUnresolvableAgent: @escaping @Sendable (any Error) async -> Void = { _ in }
    ) {
        self.orchestrator = orchestrator
        self.repoURLResolver = repoURLResolver
        self.diffProbe = diffProbe
        self.provider = provider
        self.resolveExecutable = resolveExecutable
        self.onMissingRepository = onMissingRepository
        self.onUnresolvableAgent = onUnresolvableAgent
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
            onUnresolvableAgent: onUnresolvableAgent
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
        let id = await orchestrator.spawnWorker(workerSpec)
        let terminal = await orchestrator.awaitTerminal(id)

        guard terminal?.status == .done else {
            // Crash / block / cancel: not handled, retry next poll.
            return ConversationCommentWorkResult(pushedCodeChange: false, replyBody: nil)
        }

        let pushed = await producedChanges(workerID: id)
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
        let id = await orchestrator.spawnWorker(workerSpec)
        let terminal = await orchestrator.awaitTerminal(id)

        guard terminal?.status == .done else {
            // Crash / block / cancel: not handled, retry next poll.
            return ReviewSummaryWorkResult(pushedCodeChange: false, replyBody: nil)
        }

        let pushed = await producedChanges(workerID: id)
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
    /// Provider launches target `/usr/bin/env` and prefix their arguments with the
    /// binary name (`["claude", "-p", …]`) so `env` can find the CLI on `PATH`.
    /// Once the executable is the resolved absolute path, that leading binary-name
    /// token is dropped, so the worker runs e.g. `/Users/x/.local/bin/claude -p …`.
    /// The resolver's environment is used as-is because it is already complete
    /// (inherits the process environment + augments `PATH`) — ``ProcessPaneBridge``
    /// *replaces* the child environment when it is non-empty, so a partial one would
    /// strip `HOME` and break the agent's keychain/OAuth auth.
    ///
    /// - Throws: ``WorkerAgentExecutableResolutionError`` when resolution fails.
    static func resolvedLaunch(
        base: WorkerAgentLaunch,
        providerID: AgentProviderID,
        resolve: WorkerAgentExecutableResolving
    ) throws -> WorkerAgentLaunch {
        let resolution = try resolve(providerID)
        let arguments = strippingBinaryNamePrefix(base.arguments, providerID: providerID)
        return WorkerAgentLaunch(
            executableURL: resolution.executableURL,
            arguments: arguments,
            environment: resolution.environment,
            appendPrompt: base.appendPrompt
        )
    }

    /// Drops the leading binary-name token a provider prefixes for `/usr/bin/env`.
    ///
    /// Only strips the first argument when it matches the provider's executable name
    /// (`claude`/`codex`/`gemini`), so a switch to the resolved absolute executable
    /// does not pass the CLI its own name as the first positional argument. Leaves
    /// args untouched if the prefix is already absent (idempotent).
    static func strippingBinaryNamePrefix(
        _ arguments: [String],
        providerID: AgentProviderID
    ) -> [String] {
        guard let first = arguments.first,
              first == binaryName(for: providerID) else {
            return arguments
        }
        return Array(arguments.dropFirst())
    }

    /// The CLI binary name a provider's launch prefixes for `/usr/bin/env`.
    private static func binaryName(for providerID: AgentProviderID) -> String {
        switch providerID {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        }
    }

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

    /// Builds the addressing prompt from a conversation comment's body.
    private static func conversationCommentPrompt(for request: ConversationCommentWorkRequest) -> String {
        """
        Someone left this comment on the conversation of PR \
        \(request.pullRequest.repoSlug)#\(request.pullRequest.number) \
        (by @\(request.comment.author)):

        \(request.comment.body)

        Address the comment: if it asks for a code change, make it, commit it, and \
        push. If it is a question, investigate and prepare a concise answer.
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

        Address the review: if it asks for a code change, make it, commit it, and \
        push. If it is a question, investigate and prepare a concise answer. If \
        there is genuinely nothing to do (e.g. a plain approval with no actionable \
        request), make no change and post no reply.
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

    init(
        id: String,
        pullRequest: PullRequestRef,
        branch: String,
        orchestrator: RegattaOrchestrator,
        repoURL: URL?,
        diffProbe: any RegattaDiffProbing,
        provider: any AgentProvider,
        resolveExecutable: @escaping WorkerAgentExecutableResolving = WorkerAgentExecutableResolution.defaultResolver(),
        onUnresolvableAgent: @escaping @Sendable (any Error) async -> Void = { _ in }
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
    }

    func attemptFix() async -> Bool {
        guard let repoURL else { return false }
        let prompt = """
        CI is failing on PR \(pullRequest.repoSlug)#\(pullRequest.number) \
        (branch \(branch)). Make CI green: diagnose the failing checks, fix them, \
        commit, and push.
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
            return false
        }
        let spec = WorkerSpec(
            name: "ci-fix \(pullRequest.repoSlug)#\(pullRequest.number)",
            prompt: prompt,
            repoURL: repoURL,
            agentLaunch: launch,
            providerID: provider.id
        )
        let workerID = await orchestrator.spawnWorker(spec)
        let terminal = await orchestrator.awaitTerminal(workerID)
        guard terminal?.status == .done else { return false }
        guard let worktree = await orchestrator.worktree(for: workerID) else { return false }
        return (try? await diffProbe.hasUncommittedChanges(at: worktree.path)) ?? false
    }
}
