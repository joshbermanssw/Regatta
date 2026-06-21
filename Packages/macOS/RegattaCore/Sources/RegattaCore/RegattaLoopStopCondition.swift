public import Foundation

/// The user-configured condition that ends a loop normally (as opposed to a
/// hard safety cap).
///
/// Issue #19 implements only ``manual`` and ``iterations(_:)``. The richer
/// conditions — deterministic tests (#20) and LLM-judged completion (#21) — are
/// separate issues; the engine keeps its condition check pluggable via
/// ``RegattaLoopCondition`` so those can be added without touching the core.
public enum RegattaLoopStopCondition: Equatable, Sendable {
    /// The loop runs until something external stops it (see
    /// ``RegattaLoopEngine/requestManualStop()``). It never stops on its own
    /// except via a safety cap.
    case manual

    /// The loop runs for exactly `count` iterations, then stops normally.
    ///
    /// - Parameter count: The number of iterations to run. A value `<= 0` makes
    ///   the loop stop immediately with zero iterations.
    case iterations(Int)
}
