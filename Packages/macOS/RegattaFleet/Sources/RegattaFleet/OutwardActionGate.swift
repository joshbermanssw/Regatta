public import RegattaGitHub

/// An action that escapes the local machine and must pass the autonomy gate.
///
/// The only outward action the CI fix loop takes is pushing fix commits to the
/// PR branch. Modelling it as a value keeps the gate seam narrow and lets #32's
/// real gate inspect/approve/deny each action.
public enum OutwardAction: Sendable, Equatable {
    /// Push the `ci-fix` worker's commits to the PR's head branch.
    case pushFix(pullRequest: PullRequestRef, branch: String)
}

/// The verdict the gate returns for a requested outward action.
public enum OutwardActionVerdict: Sendable, Equatable {
    /// The action was performed (or approved to be performed).
    case allowed
    /// The action was blocked by the autonomy policy; the loop must not retry it.
    case denied
}

/// The autonomy-gate seam through which every outward action is routed,
/// mirroring the gate from #32.
///
/// ## Wiring note (#32)
/// Defined locally so the CI watch loop (#30) does not push fixes without a gate
/// in place. #32 owns the real `OutwardActionGate`; when it merges the
/// composition root injects it here and this local protocol is replaced by (or
/// aliased to) #32's type. Until then, the production composition root supplies a
/// conservative gate and tests inject a stub that records and answers each
/// request.
public protocol OutwardActionGate: Sendable {
    /// Requests permission to perform — and, on approval, performs — an outward
    /// action.
    ///
    /// - Parameter action: The outward action to gate.
    /// - Returns: ``OutwardActionVerdict/allowed`` when the action proceeded,
    ///   ``OutwardActionVerdict/denied`` when policy blocked it.
    func authorize(_ action: OutwardAction) async -> OutwardActionVerdict
}
