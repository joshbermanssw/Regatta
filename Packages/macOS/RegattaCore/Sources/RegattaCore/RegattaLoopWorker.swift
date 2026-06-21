public import Foundation

/// The worker the loop engine wraps: runs exactly one iteration and reports a
/// ``RegattaLoopOutcome``.
///
/// This is the dependency-inversion seam between the loop state machine and the
/// orchestrator (#16). The engine never knows whether the worker spawns an
/// agent process, runs the fake-agent harness, or returns a canned value — it
/// just calls ``runIteration(index:goal:)`` once per loop turn. Tests inject a
/// fake conformer driven by `fake-agent.sh`.
public protocol RegattaLoopWorker: Sendable {
    /// Runs one loop iteration toward the goal and reports the outcome.
    ///
    /// - Parameters:
    ///   - index: The zero-based index of this iteration.
    ///   - goal: The loop's goal text, for context.
    /// - Returns: The classified outcome of this iteration.
    /// - Throws: Any error the worker encounters; the engine treats a thrown
    ///   error as a failed iteration and fails the loop.
    func runIteration(index: Int, goal: String) async throws -> RegattaLoopOutcome
}
