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
/// - ``OutwardAction/pushFix(pullRequest:branch:)`` becomes a
///   ``PendingAction`` with ``ActionKind/push`` and the branch carried in the
///   payload, then submitted via ``AutonomyGate/submit(_:)``.
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
        case let .pushCodeChange(threadID):
            pending = PendingAction(
                pullRequest: pullRequest,
                kind: .push,
                summary: "Push code change for thread \(threadID)",
                payload: ActionPayload(fields: ["threadID": threadID])
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
        case let .pushConversationChange(commentID):
            pending = PendingAction(
                pullRequest: pullRequest,
                kind: .push,
                summary: "Push code change for comment \(commentID)",
                payload: ActionPayload(fields: ["commentID": commentID])
            )
        case let .replyToConversation(commentID, body):
            pending = PendingAction(
                pullRequest: pullRequest,
                kind: .reply,
                summary: "Reply to conversation comment \(commentID)",
                payload: ActionPayload(fields: ["commentID": commentID, "body": body])
            )
        case let .pushReviewChange(reviewID):
            pending = PendingAction(
                pullRequest: pullRequest,
                kind: .push,
                summary: "Push code change for review \(reviewID)",
                payload: ActionPayload(fields: ["reviewID": reviewID])
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
