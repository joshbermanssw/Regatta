public import Foundation

/// A sink the orchestrator notifies when a worker reaches a terminal status
/// (issue #35).
///
/// The brain conforms to this so it learns the outcome of every worker it
/// spawned — including crashes — with the worker's retained output attached. The
/// orchestrator calls ``workerDidComplete(_:)`` exactly once per worker, right
/// after the worker transitions to a terminal status.
///
/// The observer is injected, so tests can assert the brain was notified with the
/// correct ``WorkerCompletion`` without standing up a real brain.
public protocol WorkerObserver: Sendable {
    /// Called once when a worker reaches a terminal status.
    ///
    /// - Parameter completion: The terminal report, including the worker's
    ///   retained output and whether it counts as a failed iteration.
    func workerDidComplete(_ completion: WorkerCompletion) async
}
