public import Foundation

/// An immutable report of a worker reaching a terminal status, handed to the
/// brain so it can record the outcome and count failed iterations (issue #35).
///
/// The orchestrator retains every worker's captured stdout/stderr output across
/// the run and includes it here, so a crashed worker's output is never lost even
/// though the worker is gone from the live Fleet. The brain consumes this through
/// a ``WorkerObserver`` and decides what to do (record a failed iteration, notify
/// the user, retry, etc.).
public struct WorkerCompletion: Sendable, Equatable, Identifiable {
    /// The worker's stable identifier (matches ``Worker/id``).
    public let id: UUID

    /// The worker's human-readable name.
    public let name: String

    /// The goal/prompt the worker was given.
    public let prompt: String

    /// The terminal status the worker reached (``WorkerStatus/done``,
    /// ``WorkerStatus/failed(_:)``, ``WorkerStatus/blocked(_:)``, or
    /// ``WorkerStatus/cancelled``).
    public let status: WorkerStatus

    /// The full captured output (stdout + stderr, in arrival order) the worker
    /// produced before terminating. Retained even on crash so the brain — and the
    /// user — can inspect what the agent did. Empty if the worker produced no
    /// output (or never launched).
    public let output: String

    /// Whether this completion counts as a failed iteration for the brain
    /// (issue #35: a worker crash counts as a failed iteration). Mirrors
    /// ``WorkerStatus/isFailure``.
    public var isFailedIteration: Bool { status.isFailure }

    /// Creates a worker completion report.
    public init(id: UUID, name: String, prompt: String, status: WorkerStatus, output: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.status = status
        self.output = output
    }
}
