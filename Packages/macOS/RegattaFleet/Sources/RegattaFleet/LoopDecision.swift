/// The decision a ``LoopConditionEvaluating`` returns after each iteration.
///
/// This mirrors the continue/stop control signal of the pluggable loop condition
/// in the Regatta loop engine (#19). When #19 merges, ``CIFixLoopCondition``
/// becomes a `RegattaLoopCondition` conformer and this enum is replaced by (or
/// bridged to) the engine's own decision type.
public enum LoopDecision: Sendable, Equatable {
    /// Keep iterating: the exit condition has not been met yet.
    case continueLooping
    /// Stop iterating: the exit condition has been met.
    case stop
}
