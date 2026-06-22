public import RegattaGitHub

/// Handles a single PR conversation comment end-to-end: spawn an addressing
/// worker, then (subject to the autonomy gate) push a code change and post a
/// reply in the PR conversation.
///
/// One `ConversationCommentWorker` exists per comment the reactor decides to
/// address. It owns no diffing or idempotency logic — that is
/// ``ConversationCommentReactor``'s job; the worker simply performs the
/// addressing flow once and reports whether the comment was fully handled.
///
/// ## Action ordering and the gate
/// Every outward step is described as an ``OutwardAction`` and authorised through
/// the injected ``OutwardActionGate`` before it runs. If the gate suppresses
/// **any** required step, the worker logs the suppression and reports the comment
/// as *not* handled, so a later autonomy change lets the next poll retry it.
///
/// ## Loop safety
/// The reply posted here is authored by the shepherd's own `gh` identity. The
/// reactor filters out comments authored by that identity, so this reply is never
/// itself reacted to — the worker therefore cannot trigger an infinite
/// reply-to-own-reply loop.
///
/// ## Concurrency
/// `struct` with no mutable state; all dependencies are injected `Sendable`
/// seams. Each call to ``handle(_:in:)`` is independent.
public struct ConversationCommentWorker: Sendable {
    private let spawner: any WorkerSpawning
    private let writer: any PullRequestWriting
    private let gate: any OutwardActionGate
    private let log: any ConversationCommentActivityLogging

    /// Creates a worker.
    ///
    /// - Parameters:
    ///   - spawner: The seam that spawns the addressing agent.
    ///   - writer: The GitHub write seam used to post the conversation reply.
    ///   - gate: The autonomy gate every outward action is routed through (#32).
    ///   - log: The per-comment activity log.
    public init(
        spawner: any WorkerSpawning,
        writer: any PullRequestWriting,
        gate: any OutwardActionGate,
        log: any ConversationCommentActivityLogging
    ) {
        self.spawner = spawner
        self.writer = writer
        self.gate = gate
        self.log = log
    }

    /// Addresses one conversation comment.
    ///
    /// Spawns a worker for the comment, then performs the outward actions its
    /// result calls for — each gated and logged.
    ///
    /// - Parameters:
    ///   - comment: The comment to address.
    ///   - pullRequest: The PR the comment belongs to.
    /// - Returns: `true` if the comment was fully handled (every required outward
    ///   action either completed or was intentionally not requested); `false` if
    ///   any step was suppressed by the gate or failed, leaving the comment open
    ///   for a later retry.
    @discardableResult
    public func handle(_ comment: PRConversationComment, in pullRequest: PullRequestRef) async -> Bool {
        await log.log(.init(pullRequest: pullRequest, commentID: comment.id, event: .spawnedWorker))

        let result: ConversationCommentWorkResult
        do {
            result = try await spawner.spawnWorker(
                for: ConversationCommentWorkRequest(pullRequest: pullRequest, comment: comment)
            )
        } catch {
            await log.log(.init(
                pullRequest: pullRequest,
                commentID: comment.id,
                event: .failed(reason: "\(error)")
            ))
            return false
        }

        var fullyHandled = true

        if result.pushedCodeChange {
            let action = OutwardAction.pushConversationChange(commentID: comment.id)
            if await gate.authorize(action, for: pullRequest) == .allowed {
                // The worker already produced the change; the gate only governs
                // whether it is allowed to leave the machine.
                await log.log(.init(
                    pullRequest: pullRequest, commentID: comment.id, event: .pushedCodeChange
                ))
            } else {
                await log.log(.init(
                    pullRequest: pullRequest, commentID: comment.id, event: .suppressedByGate(action)
                ))
                fullyHandled = false
            }
        }

        if let body = result.replyBody {
            let action = OutwardAction.replyToConversation(commentID: comment.id, body: body)
            if await gate.authorize(action, for: pullRequest) == .allowed {
                do {
                    try await writer.postConversationComment(
                        owner: pullRequest.owner,
                        repo: pullRequest.repo,
                        prNumber: pullRequest.number,
                        body: body
                    )
                    await log.log(.init(
                        pullRequest: pullRequest, commentID: comment.id, event: .postedReply(body: body)
                    ))
                } catch {
                    await log.log(.init(
                        pullRequest: pullRequest, commentID: comment.id, event: .failed(reason: "\(error)")
                    ))
                    fullyHandled = false
                }
            } else {
                await log.log(.init(
                    pullRequest: pullRequest, commentID: comment.id, event: .suppressedByGate(action)
                ))
                fullyHandled = false
            }
        }

        return fullyHandled
    }
}
