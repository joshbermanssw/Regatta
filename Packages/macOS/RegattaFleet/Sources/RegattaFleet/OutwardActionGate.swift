public import RegattaGitHub

/// A description of an outward, side-effecting action a PR shepherd wants to
/// take — pushing a fix, replying to a review thread, resolving a thread, or
/// pushing a code change addressing a thread.
///
/// Every action that reaches outside the app is described by one of these cases
/// and routed through an ``OutwardActionGate`` before it runs. Modelling the
/// action as a value (rather than calling the side effect directly) lets the
/// autonomy layer (issue #32) decide *whether* and *when* it executes without
/// the reactive layer (issues #30 / #31) knowing the policy.
public enum OutwardAction: Sendable, Equatable {
    /// Push the `ci-fix` worker's commits to the PR's head branch (issue #30).
    case pushFix(pullRequest: PullRequestRef, branch: String)

    /// Post a reply tied to a review thread (issue #31).
    /// - Parameters:
    ///   - threadID: The GitHub node ID of the thread being replied to.
    ///   - body: The markdown reply body.
    case replyToThread(threadID: String, body: String)

    /// Resolve a review thread (issue #31).
    /// - Parameter threadID: The GitHub node ID of the thread being resolved.
    case resolveThread(threadID: String)

    /// Push a code change addressing a review thread (issue #31).
    /// - Parameter threadID: The GitHub node ID of the thread the change
    ///   addresses.
    case pushCodeChange(threadID: String)

    /// Post a reply to a top-level PR conversation comment.
    /// - Parameters:
    ///   - commentID: The id of the conversation comment being replied to.
    ///   - body: The markdown reply body.
    case replyToConversation(commentID: String, body: String)

    /// Push a code change addressing a top-level PR conversation comment.
    /// - Parameter commentID: The id of the conversation comment the change
    ///   addresses.
    case pushConversationChange(commentID: String)
}

/// The verdict the gate returns for a requested outward action.
public enum OutwardActionVerdict: Sendable, Equatable {
    /// The action was performed (or approved to be performed now).
    case allowed
    /// The action was blocked or deferred by the autonomy policy; the caller must
    /// not treat it as done and must not retry it this iteration.
    case denied
}

/// The single autonomy-gate seam through which every outward action is routed
/// before it runs.
///
/// This is the **autonomy boundary**. Issues #30 (ci-fix) and #31 (review
/// threads) decide *what* a shepherd should do; issue #32 (the autonomy policy)
/// decides whether the user has authorised it. Defining one seam here — rather
/// than importing #32's concrete gate — lets each reactive layer ship and be
/// tested independently; the real ``AutonomyGate`` conforms to this protocol (see
/// `AutonomyGate+OutwardActionGate`) and the composition root injects it.
///
/// A conformer returns ``OutwardActionVerdict/allowed`` to authorise the action
/// and ``OutwardActionVerdict/denied`` to suppress or defer it. A denied action
/// is not performed and (critically) does **not** mark the work as handled, so a
/// later autonomy change can pick it up on the next poll.
public protocol OutwardActionGate: Sendable {
    /// Decides whether — and, for an auto-mode gate, performs — an outward action.
    ///
    /// - Parameters:
    ///   - action: The action awaiting authorisation.
    ///   - pullRequest: The PR the action targets, for per-PR policy.
    /// - Returns: ``OutwardActionVerdict/allowed`` when the action proceeded,
    ///   ``OutwardActionVerdict/denied`` when policy blocked or deferred it.
    func authorize(_ action: OutwardAction, for pullRequest: PullRequestRef) async -> OutwardActionVerdict
}

/// A permissive ``OutwardActionGate`` that authorises every action.
///
/// This is the placeholder default used at the composition root and in tests
/// that don't exercise the autonomy policy. Production wires the real
/// ``AutonomyGate`` instead.
public struct AllowAllOutwardActionGate: OutwardActionGate {
    /// Creates a permissive gate.
    public init() {}

    /// Always authorises the action.
    public func authorize(_ action: OutwardAction, for pullRequest: PullRequestRef) async -> OutwardActionVerdict {
        .allowed
    }
}
