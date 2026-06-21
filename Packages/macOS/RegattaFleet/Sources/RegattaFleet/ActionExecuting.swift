/// The execution seam every outward-facing action runs through once the
/// ``AutonomyGate`` decides it may proceed.
///
/// **This is the contract #30 (push) and #31 (reply/resolve) implement.** Issue
/// #32 deliberately ships no `gh` writes; it only owns the *gating policy*. The
/// gate calls ``execute(_:)`` exactly once per action — immediately in
/// ``AutonomyMode/auto`` mode, or after the user approves in
/// ``AutonomyMode/staged`` mode — and never for a rejected action.
///
/// An executor inspects the action's ``PendingAction/kind`` and
/// ``PendingAction/payload`` and performs the real side effect (push commits,
/// post a reply, resolve a thread). Throwing marks the action
/// ``ActionStatus/failed``; returning normally marks it ``ActionStatus/completed``.
///
/// ## Why a protocol and not a closure on the action
/// Keeping execution behind a `Sendable` protocol (rather than an async closure
/// captured inside ``PendingAction``) lets the action value stay a pure,
/// `Codable`, `Equatable` snapshot that crosses the actor boundary into the
/// `@MainActor` view layer and feeds list rows directly — honouring the
/// snapshot-boundary rule. The gate holds the executor; the view holds only
/// values.
public protocol ActionExecuting: Sendable {
    /// Performs the real side effect for an approved/auto action.
    ///
    /// - Parameter action: The action to execute. Its ``PendingAction/kind`` and
    ///   ``PendingAction/payload`` describe what to do.
    /// - Throws: Any error; the gate maps a throw to ``ActionStatus/failed``.
    func execute(_ action: PendingAction) async throws
}

/// An ``ActionExecuting`` that does nothing and always succeeds.
///
/// Used as the default executor until #30/#31 land their real `gh`-backed
/// executors. With this in place, ``AutonomyMode/auto`` mode "executes"
/// instantly (a no-op) and ``AutonomyMode/staged`` mode still exercises the full
/// approve/reject queue — so the gating policy is fully testable before any
/// network write exists.
public struct NoopActionExecutor: ActionExecuting {
    /// Creates a no-op executor.
    public init() {}

    /// Succeeds without performing any side effect.
    public func execute(_ action: PendingAction) async throws {}
}
