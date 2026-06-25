import RegattaGitHub

/// Routes the CI-fix loop's ``OutwardActionGate`` requests (issue #30) through
/// the real ``AutonomyGate`` (issue #32).
///
/// This is the integration seam the CI-fix branch documented: instead of a local
/// stub gate, the composition root injects the shared ``AutonomyGate`` so every
/// outward push the ci-fix loop wants to make is subject to the same per-PR
/// autonomy policy (auto vs. staged) and the same approve/reject queue the
/// shepherd card renders.
///
/// ## Mapping
/// - Every push-kind action — ``OutwardAction/pushFix(pullRequest:branch:)`` and
///   the three addressing pushes (``OutwardAction/pushCodeChange(threadID:branch:)``,
///   ``OutwardAction/pushConversationChange(commentID:branch:)``,
///   ``OutwardAction/pushReviewChange(reviewID:branch:)``) — becomes a
///   ``PendingAction`` with ``ActionKind/push`` and the **head branch carried in
///   the payload**, then submitted via ``AutonomyGate/submit(_:)``. The branch is
///   load-bearing: the production ``GitPushActionExecutor`` requires it, so an
///   addressing push that omitted it threw ``GitPushActionError/missingBranch``
///   and the gate denied it forever (the respawn-forever bug).
/// - ``AutonomyMode/auto`` ⇒ the push executes immediately; a clean execution
///   maps to ``OutwardActionVerdict/allowed``.
/// - ``AutonomyMode/staged`` ⇒ the push is enqueued for the user's approval and
///   has *not* happened yet, so the loop is told ``OutwardActionVerdict/denied``
///   (it must not treat the push as done). When the user later approves the
///   queued action, the gate's executor performs it out of band.
/// - An execution that throws also maps to ``OutwardActionVerdict/denied`` so the
///   loop does not assume a failed push succeeded.
extension AutonomyGate: OutwardActionGate {
    /// Submits the outward action to the autonomy gate and maps the gate's
    /// ``SubmitResult`` to an ``OutwardActionVerdict``.
    public func authorize(_ action: OutwardAction, for pullRequest: PullRequestRef) async -> OutwardActionVerdict {
        let pending: PendingAction
        switch action {
        case let .pushFix(_, branch):
            pending = PendingAction(
                pullRequest: pullRequest,
                kind: .push,
                summary: "Push ci-fix commits to \(branch)",
                payload: ActionPayload(fields: ["branch": branch])
            )
        case let .pushCodeChange(threadID, branch):
            pending = PendingAction(
                pullRequest: pullRequest,
                kind: .push,
                summary: "Push code change for thread \(threadID) to \(branch)",
                payload: ActionPayload(fields: ["threadID": threadID, "branch": branch])
            )
        case let .replyToThread(threadID, body):
            pending = PendingAction(
                pullRequest: pullRequest,
                kind: .reply,
                summary: "Reply to review thread \(threadID)",
                payload: ActionPayload(fields: ["threadID": threadID, "body": body])
            )
        case let .resolveThread(threadID):
            pending = PendingAction(
                pullRequest: pullRequest,
                kind: .resolve,
                summary: "Resolve review thread \(threadID)",
                payload: ActionPayload(fields: ["threadID": threadID])
            )
        case let .pushConversationChange(commentID, branch):
            pending = PendingAction(
                pullRequest: pullRequest,
                kind: .push,
                summary: "Push code change for comment \(commentID) to \(branch)",
                payload: ActionPayload(fields: ["commentID": commentID, "branch": branch])
            )
        case let .replyToConversation(commentID, body):
            pending = PendingAction(
                pullRequest: pullRequest,
                kind: .reply,
                summary: "Reply to conversation comment \(commentID)",
                payload: ActionPayload(fields: ["commentID": commentID, "body": body])
            )
        case let .pushReviewChange(reviewID, branch):
            pending = PendingAction(
                pullRequest: pullRequest,
                kind: .push,
                summary: "Push code change for review \(reviewID) to \(branch)",
                payload: ActionPayload(fields: ["reviewID": reviewID, "branch": branch])
            )
        case let .replyToReview(reviewID, body):
            pending = PendingAction(
                pullRequest: pullRequest,
                kind: .reply,
                summary: "Reply to review \(reviewID)",
                payload: ActionPayload(fields: ["reviewID": reviewID, "body": body])
            )
        }
        switch await submit(pending) {
        case .executed:
            return .allowed
        case .enqueued, .executionFailed:
            return .denied
        }
    }
}
