public import RegattaGitHub

/// Handles a single submitted review (review summary) end-to-end: spawn an
/// addressing worker, then (subject to the autonomy gate) push a code change and
/// post a reply on the PR.
///
/// One `ReviewSummaryWorker` exists per review the reactor decides to address. It
/// owns no diffing or idempotency logic — that is ``ReviewSummaryReactor``'s job;
/// the worker simply performs the addressing flow once and reports whether the
/// review was fully handled.
///
/// ## Nothing-to-do (pure approvals)
/// When the worker reports neither a pushed change nor a reply body (the typical
/// outcome for a plain approval), the worker logs ``ReviewSummaryActivity/Event/nothingToDo``,
/// posts no reply, and reports the review as **handled** — there is nothing left
/// to do, so it must not be retried forever.
///
/// ## Action ordering and the gate
/// Every outward step is described as an ``OutwardAction`` and authorised through
/// the injected ``OutwardActionGate`` before it runs. If the gate suppresses a
/// required step, the worker logs the suppression and reports the review as *not*
/// handled, so a later autonomy change lets the next poll retry it.
///
/// ## Loop safety
/// The reply posted here is authored by the shepherd's own `gh` identity. The
/// reactor filters out reviews authored by that identity, so this reply never
/// triggers a reply-to-own-review loop.
///
/// ## Concurrency
/// `struct` with no mutable state; all dependencies are injected `Sendable`
/// seams. Each call to ``handle(_:in:)`` is independent.
public struct ReviewSummaryWorker: Sendable {
    private let spawner: any WorkerSpawning
    private let writer: any PullRequestWriting
    private let gate: any OutwardActionGate
    private let log: any ReviewSummaryActivityLogging

    /// Resolves the PR's **head branch** the gate-routed push targets. When `nil`
    /// the worker declines the push rather than pushing to a wrong branch (the
    /// ci-fix decline guard). See ``ReviewThreadWorker`` for the rationale.
    private let headBranchResolver: @Sendable (PullRequestRef) async -> String?

    /// Creates a worker.
    ///
    /// - Parameters:
    ///   - spawner: The seam that spawns the addressing agent.
    ///   - writer: The GitHub write seam used to post the reply.
    ///   - gate: The autonomy gate every outward action is routed through (#32).
    ///   - log: The per-review activity log.
    ///   - headBranchResolver: Resolves the PR head branch the push targets;
    ///     `nil` makes the worker decline the push.
    public init(
        spawner: any WorkerSpawning,
        writer: any PullRequestWriting,
        gate: any OutwardActionGate,
        log: any ReviewSummaryActivityLogging,
        headBranchResolver: @escaping @Sendable (PullRequestRef) async -> String? = { _ in nil }
    ) {
        self.spawner = spawner
        self.writer = writer
        self.gate = gate
        self.log = log
        self.headBranchResolver = headBranchResolver
    }

    /// Addresses one submitted review.
    ///
    /// Spawns a worker for the review, then performs the outward actions its
    /// result calls for — each gated and logged.
    ///
    /// - Parameters:
    ///   - review: The review to address.
    ///   - pullRequest: The PR the review belongs to.
    /// - Returns: `true` if the review was fully handled (every required outward
    ///   action either completed, was intentionally not requested, or there was
    ///   nothing to do); `false` if any step was suppressed by the gate or
    ///   failed, leaving the review open for a later retry.
    @discardableResult
    public func handle(_ review: PRReview, in pullRequest: PullRequestRef) async -> Bool {
        await log.log(.init(pullRequest: pullRequest, reviewID: review.id, event: .spawnedWorker))

        let result: ReviewSummaryWorkResult
        do {
            result = try await spawner.spawnWorker(
                for: ReviewSummaryWorkRequest(pullRequest: pullRequest, review: review)
            )
        } catch {
            await log.log(.init(
                pullRequest: pullRequest,
                reviewID: review.id,
                event: .failed(reason: "\(error)")
            ))
            return false
        }

        var fullyHandled = true

        if result.pushedCodeChange {
            // Resolve the PR head branch; decline (leave for retry) when unknown so
            // the push never lands on a junk branch — the ci-fix decline guard.
            guard let branch = await headBranchResolver(pullRequest), !branch.isEmpty else {
                await log.log(.init(
                    pullRequest: pullRequest, reviewID: review.id,
                    event: .failed(reason: ReviewThreadWorker.unresolvedBranchReason)
                ))
                return false
            }
            // Route the push through the gate carrying the head branch so the
            // production executor can run the real push (staged holds; auto runs).
            let action = OutwardAction.pushReviewChange(reviewID: review.id, branch: branch)
            if await gate.authorize(action, for: pullRequest) == .allowed {
                await log.log(.init(
                    pullRequest: pullRequest, reviewID: review.id, event: .pushedCodeChange
                ))
            } else {
                await log.log(.init(
                    pullRequest: pullRequest, reviewID: review.id, event: .suppressedByGate(action)
                ))
                fullyHandled = false
            }
        }

        if let body = result.replyBody {
            let action = OutwardAction.replyToReview(reviewID: review.id, body: body)
            if await gate.authorize(action, for: pullRequest) == .allowed {
                do {
                    try await writer.postConversationComment(
                        owner: pullRequest.owner,
                        repo: pullRequest.repo,
                        prNumber: pullRequest.number,
                        body: body
                    )
                    await log.log(.init(
                        pullRequest: pullRequest, reviewID: review.id, event: .postedReply(body: body)
                    ))
                } catch {
                    await log.log(.init(
                        pullRequest: pullRequest, reviewID: review.id, event: .failed(reason: "\(error)")
                    ))
                    fullyHandled = false
                }
            } else {
                await log.log(.init(
                    pullRequest: pullRequest, reviewID: review.id, event: .suppressedByGate(action)
                ))
                fullyHandled = false
            }
        } else if !result.pushedCodeChange {
            // No push and no reply: the agent determined there was nothing to do
            // (e.g. a pure approval). Record it and treat the review as handled.
            await log.log(.init(
                pullRequest: pullRequest, reviewID: review.id, event: .nothingToDo
            ))
        }

        return fullyHandled
    }
}
