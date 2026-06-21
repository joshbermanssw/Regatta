public import Foundation

/// An immutable snapshot of a Fleet worker's identity and current status.
///
/// The orchestrator yields a fresh `Worker` snapshot every time a worker's status
/// changes. The Fleet UI feeds these value snapshots into its `ForEach` rows so no
/// `@Observable`/actor reference ever crosses the SwiftUI list snapshot boundary
/// (CLAUDE.md snapshot-boundary rule).
public struct Worker: Identifiable, Sendable, Equatable {
    /// A stable identifier for the worker, used to address it for cancellation.
    public let id: UUID

    /// The human-readable name shown in the Fleet list.
    public let name: String

    /// The goal/prompt the worker was given.
    public let prompt: String

    /// The current lifecycle status, reflected by the row's status dot.
    public let status: WorkerStatus

    /// The CLI agent provider this worker is running (issue #36), surfaced in the
    /// Fleet UI so the chosen agent is visible on the worker.
    public let providerID: AgentProviderID

    /// Creates a `Worker` snapshot.
    ///
    /// - Parameters:
    ///   - id: A stable identifier for the worker.
    ///   - name: The human-readable name shown in the Fleet list.
    ///   - prompt: The goal/prompt the worker was given.
    ///   - status: The current lifecycle status.
    ///   - providerID: The CLI agent provider the worker is running. Defaults to
    ///     ``AgentProviderID/default``.
    public init(
        id: UUID,
        name: String,
        prompt: String,
        status: WorkerStatus,
        providerID: AgentProviderID = .default
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.status = status
        self.providerID = providerID
    }

    /// Returns a copy of this snapshot with a new status.
    ///
    /// - Parameter newStatus: The status for the returned snapshot.
    /// - Returns: A copy identical except for ``status``.
    public func withStatus(_ newStatus: WorkerStatus) -> Worker {
        Worker(id: id, name: name, prompt: prompt, status: newStatus, providerID: providerID)
    }
}
