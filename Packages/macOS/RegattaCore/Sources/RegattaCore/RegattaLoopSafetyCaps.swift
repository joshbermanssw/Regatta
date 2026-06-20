/// Hard safety limits that force-stop a runaway loop regardless of its
/// configured ``RegattaLoopStopCondition``.
///
/// Caps are a backstop, not a normal exit: when a cap trips the loop is marked
/// stopped-by-cap (see ``RegattaLoopStopReason``) so the UI can distinguish a
/// goal-reached run from a clamped one. Caps are checked *before* each iteration
/// is started, so they never permit one extra over-budget iteration.
public struct RegattaLoopSafetyCaps: Equatable, Sendable {
    /// The maximum number of iterations the loop may run. Must be `>= 0`.
    ///
    /// When the completed iteration count reaches this value, the loop stops via
    /// ``RegattaLoopStopReason/maxIterationsCap``.
    public let maxIterations: Int

    /// The maximum total tokens the loop may consume across all iterations, or
    /// `nil` for no token cap.
    ///
    /// Before each iteration the engine checks whether the running token total
    /// has reached this budget; if so the loop stops via
    /// ``RegattaLoopStopReason/tokenBudgetCap``.
    public let tokenBudget: Int?

    /// Creates a set of safety caps.
    ///
    /// - Parameters:
    ///   - maxIterations: The hard iteration ceiling (default `50`).
    ///   - tokenBudget: The hard token ceiling, or `nil` for none (default `nil`).
    public init(maxIterations: Int = 50, tokenBudget: Int? = nil) {
        self.maxIterations = max(0, maxIterations)
        self.tokenBudget = tokenBudget
    }
}
