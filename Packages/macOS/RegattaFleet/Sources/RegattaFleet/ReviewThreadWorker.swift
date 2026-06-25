public import RegattaGitHub

/// Handles a single review thread end-to-end: spawn an addressing worker, then
/// (subject to the autonomy gate) push a code change, post a reply tied to the
/// thread, and resolve it.
///
/// One `ReviewThreadWorker` exists per thread the reactor decides to address. It
/// owns no diffing or idempotency logic — that is ``ReviewThreadReactor``'s job;
/// the worker simply performs the addressing flow once and reports whether the
/// thread was fully handled.
///
/// ## Action ordering and the gate
/// Every outward step is described as an ``OutwardAction`` and authorised
/// through the injected ``OutwardActionGate`` before it runs. If the gate
/// suppresses **any** required step, the worker logs the suppression and reports
/// the thread as *not* handled, so a later autonomy change (issue #32) lets the
/// next poll retry it.
///
/// ## Concurrency
/// `struct` with no mutable state; all dependencies are injected `Sendable`
/// seams. Each call to ``handle(_:in:)`` is independent.
public struct ReviewThreadWorker: Sendable {
    private let spawner: any WorkerSpawning
    private let writer: any PullRequestWriting
    private let gate: any OutwardActionGate
    private let log: any ReviewThreadActivityLogging

    /// Resolves the PR's **head branch** — the branch the gate-routed push targets
    /// (`git push origin HEAD:<branch>`). Mirrors the ci-fix design: the worker
    /// holds only a ``PullRequestRef``, which does not carry the head branch, so
    /// the composition root injects this resolver (backed by the per-PR
    /// head-branch map recorded at handoff). When it returns `nil` the worker
    /// **declines the push** rather than pushing to a wrong (junk) branch, leaving
    /// the thread unhandled for a later retry. Defaults to `nil` so tests that do
    /// not exercise a push need not supply it.
    private let headBranchResolver: @Sendable (PullRequestRef) async -> String?

    /// Creates a worker.
    ///
    /// - Parameters:
    ///   - spawner: The seam that spawns the addressing agent (issue #16).
    ///   - writer: The GitHub write seam used to reply and resolve.
    ///   - gate: The autonomy gate every outward action is routed through (#32).
    ///   - log: The per-thread activity log.
    ///   - headBranchResolver: Resolves the PR head branch the push targets;
    ///     `nil` makes the worker decline the push (see ``headBranchResolver``).
    public init(
        spawner: any WorkerSpawning,
        writer: any PullRequestWriting,
        gate: any OutwardActionGate,
        log: any ReviewThreadActivityLogging,
        headBranchResolver: @escaping @Sendable (PullRequestRef) async -> String? = { _ in nil }
    ) {
        self.spawner = spawner
        self.writer = writer
        self.gate = gate
        self.log = log
        self.headBranchResolver = headBranchResolver
    }

    /// Addresses one review thread.
    ///
    /// Spawns a worker for the thread, then performs the outward actions its
    /// result calls for — each gated and logged.
    ///
    /// - Parameters:
    ///   - thread: The thread to address.
    ///   - pullRequest: The PR the thread belongs to.
    /// - Returns: `true` if the thread was fully handled (every required outward
    ///   action either completed or was intentionally not requested); `false` if
    ///   any step was suppressed by the gate or failed, leaving the thread open
    ///   for a later retry.
    @discardableResult
    public func handle(_ thread: ReviewThread, in pullRequest: PullRequestRef) async -> Bool {
        await log.log(.init(pullRequest: pullRequest, threadID: thread.id, event: .spawnedWorker))

        let result: ReviewThreadWorkResult
        do {
            result = try await spawner.spawnWorker(
                for: ReviewThreadWorkRequest(pullRequest: pullRequest, thread: thread)
            )
        } catch {
            await log.log(.init(
                pullRequest: pullRequest,
                threadID: thread.id,
                event: .failed(reason: "\(error)")
            ))
            return false
        }

        var fullyHandled = true

        if result.pushedCodeChange {
            // Resolve the PR's real head branch so the gate-routed push targets the
            // PR (`git push origin HEAD:<branch>`). When the head branch is unknown
            // the worker must NOT push (the push would land on a junk branch named
            // after the repo): decline, leave the thread unhandled for a retry, and
            // surface needs-attention — exactly the ci-fix decline guard.
            guard let branch = await headBranchResolver(pullRequest), !branch.isEmpty else {
                await log.log(.init(
                    pullRequest: pullRequest, threadID: thread.id,
                    event: .failed(reason: Self.unresolvedBranchReason)
                ))
                return false
            }
            // The worker committed locally (it is prompted to commit, not push).
            // Route the *push* through the autonomy gate carrying the head branch so
            // the production GitPushActionExecutor can run the real push (staged
            // holds it for approval; auto executes it immediately).
            let action = OutwardAction.pushCodeChange(threadID: thread.id, branch: branch)
            if await gate.authorize(action, for: pullRequest) == .allowed {
                await log.log(.init(
                    pullRequest: pullRequest, threadID: thread.id, event: .pushedCodeChange
                ))
            } else {
                await log.log(.init(
                    pullRequest: pullRequest, threadID: thread.id, event: .suppressedByGate(action)
                ))
                fullyHandled = false
            }
        }

        if let body = result.replyBody {
            let action = OutwardAction.replyToThread(threadID: thread.id, body: body)
            if await gate.authorize(action, for: pullRequest) == .allowed {
                do {
                    try await writer.replyToReviewThread(threadID: thread.id, body: body)
                    await log.log(.init(
                        pullRequest: pullRequest, threadID: thread.id, event: .postedReply(body: body)
                    ))
                } catch {
                    await log.log(.init(
                        pullRequest: pullRequest, threadID: thread.id, event: .failed(reason: "\(error)")
                    ))
                    fullyHandled = false
                }
            } else {
                await log.log(.init(
                    pullRequest: pullRequest, threadID: thread.id, event: .suppressedByGate(action)
                ))
                fullyHandled = false
            }
        }

        // Only resolve when the thread was addressed without any suppressed or
        // failed step — resolving a half-addressed thread would hide it.
        if result.shouldResolve, fullyHandled {
            let action = OutwardAction.resolveThread(threadID: thread.id)
            if await gate.authorize(action, for: pullRequest) == .allowed {
                do {
                    try await writer.resolveReviewThread(threadID: thread.id)
                    await log.log(.init(
                        pullRequest: pullRequest, threadID: thread.id, event: .resolvedThread
                    ))
                } catch {
                    await log.log(.init(
                        pullRequest: pullRequest, threadID: thread.id, event: .failed(reason: "\(error)")
                    ))
                    fullyHandled = false
                }
            } else {
                await log.log(.init(
                    pullRequest: pullRequest, threadID: thread.id, event: .suppressedByGate(action)
                ))
                fullyHandled = false
            }
        }

        return fullyHandled
    }

    /// The activity-log reason recorded when the worker produced a change but the
    /// PR's head branch could not be resolved, so the push was held rather than
    /// pushed to a wrong branch.
    static let unresolvedBranchReason =
        "A fix is ready but the PR's head branch couldn't be resolved, so the push was held to avoid pushing to the wrong branch"
}
