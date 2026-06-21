public import Foundation
public import RegattaCore

/// A `Codable` snapshot of a single Fleet worker's persistable identity and
/// last-known status (issue #34).
///
/// A worker's live agent process is **not** resumed across a restart, so what we
/// persist is its definition (id, name, prompt, provider) plus the status it had
/// when the snapshot was taken. On restore, a worker that was mid-flight is
/// re-presented as ``WorkerStatus/interrupted`` so it can be relaunched — see
/// ``RegattaRestorePlanner``.
public struct WorkerSnapshot: Sendable, Equatable, Codable, Identifiable {
    /// The worker's stable identifier.
    public let id: UUID

    /// The human-readable name shown in the Fleet list.
    public let name: String

    /// The goal/prompt the worker was given.
    public let prompt: String

    /// The status recorded when the snapshot was written.
    public let status: WorkerStatus

    /// The CLI agent provider the worker runs.
    public let providerID: AgentProviderID

    /// Creates a worker snapshot.
    ///
    /// - Parameters:
    ///   - id: The worker's stable identifier.
    ///   - name: The human-readable name.
    ///   - prompt: The goal/prompt.
    ///   - status: The recorded status.
    ///   - providerID: The agent provider id.
    public init(
        id: UUID,
        name: String,
        prompt: String,
        status: WorkerStatus,
        providerID: AgentProviderID
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.status = status
        self.providerID = providerID
    }

    /// Captures a ``Worker`` value into a persistable snapshot.
    ///
    /// - Parameter worker: The live worker snapshot to persist.
    public init(worker: Worker) {
        self.init(
            id: worker.id,
            name: worker.name,
            prompt: worker.prompt,
            status: worker.status,
            providerID: worker.providerID
        )
    }

    /// Rebuilds a ``Worker`` value from this snapshot.
    ///
    /// The status is used verbatim; call ``RegattaRestorePlanner`` to apply the
    /// restore mapping (previously-live → ``WorkerStatus/interrupted``).
    public func makeWorker() -> Worker {
        Worker(id: id, name: name, prompt: prompt, status: status, providerID: providerID)
    }
}
