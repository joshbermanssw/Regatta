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

    /// Creates a worker.
    ///
    /// - Parameters:
    ///   - spawner: The seam that spawns the addressing agent (issue #16).
    ///   - writer: The GitHub write seam used to reply and resolve.
    ///   - gate: The autonomy gate every outward action is routed through (#32).
    ///   - log: The per-thread activity log.
    public init(
        spawner: any WorkerSpawning,
        writer: any PullRequestWriting,
        gate: any OutwardActionGate,
        log: any ReviewThreadActivityLogging
    ) {
        self.spawner = spawner
        self.writer = writer
        self.gate = gate
        self.log = log
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
            let action = OutwardAction.pushCodeChange(threadID: thread.id)
            if await gate.authorize(action, for: pullRequest) {
                // The worker already produced the change; the gate only governs
                // whether it is allowed to leave the machine. The spawner is the
                // push seam (issue #16), so there is nothing more to invoke here.
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
            if await gate.authorize(action, for: pullRequest) {
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
            if await gate.authorize(action, for: pullRequest) {
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
}
