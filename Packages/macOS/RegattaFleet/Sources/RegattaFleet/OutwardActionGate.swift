/// A description of an outward, side-effecting action a PR shepherd wants to
/// take in response to a reviewer's comment.
///
/// Every action that reaches outside the app — posting a reply, resolving a
/// thread, pushing a code change — is described by one of these cases and routed
/// through an ``OutwardActionGate`` before it runs. Modelling the action as a
/// value (rather than calling the side effect directly) lets the autonomy layer
/// (issue #32) decide *whether* and *when* it executes without the reactive
/// layer knowing the policy.
public enum OutwardAction: Sendable, Equatable {
    /// Post a reply tied to a review thread.
    /// - Parameters:
    ///   - threadID: The GitHub node ID of the thread being replied to.
    ///   - body: The markdown reply body.
    case replyToThread(threadID: String, body: String)

    /// Resolve a review thread.
    /// - Parameter threadID: The GitHub node ID of the thread being resolved.
    case resolveThread(threadID: String)

    /// Push a code change addressing a review thread.
    /// - Parameter threadID: The GitHub node ID of the thread the change
    ///   addresses.
    case pushCodeChange(threadID: String)
}

/// The gate seam through which every outward review-thread action is authorised
/// before it runs.
///
/// This is the **autonomy boundary**. Issue #31 (review-thread handling) decides
/// *what* the shepherd should do; issue #32 (the autonomy setting) decides
/// whether the user has authorised it. Defining the seam here — rather than
/// importing #32's concrete gate — lets the reactive layer ship and be tested
/// independently; when #32 lands, its gate conforms to this protocol and is
/// injected at the composition root.
///
/// A conformer returns `true` to authorise the action and `false` to suppress
/// it. A suppressed action is logged but not performed, and (critically) does
/// **not** mark the thread as handled, so a later autonomy change can pick it up
/// on the next poll.
///
/// ```swift
/// // Until #32 lands, the app wires the permissive default:
/// let gate: any OutwardActionGate = AllowAllOutwardActionGate()
///
/// // Tests inject a recording gate that can deny specific actions.
/// let gate: any OutwardActionGate = RecordingGate(allow: false)
/// ```
public protocol OutwardActionGate: Sendable {
    /// Decides whether an outward action may run.
    ///
    /// - Parameters:
    ///   - action: The action awaiting authorisation.
    ///   - pullRequest: The PR the action targets, for policy that varies per PR.
    /// - Returns: `true` to authorise the action, `false` to suppress it.
    func authorize(_ action: OutwardAction, for pullRequest: PullRequestRef) async -> Bool
}

/// A permissive ``OutwardActionGate`` that authorises every action.
///
/// This is the placeholder default used at the composition root until the real
/// autonomy gate from issue #32 is wired in. It exists so the review-thread
/// reactive layer is fully exercisable end-to-end before #32 merges; it must be
/// replaced by the policy-aware gate, not shipped as the production default.
public struct AllowAllOutwardActionGate: OutwardActionGate {
    /// Creates a permissive gate.
    public init() {}

    /// Always authorises the action.
    public func authorize(_ action: OutwardAction, for pullRequest: PullRequestRef) async -> Bool {
        true
    }
}
