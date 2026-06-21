public import RegattaCore

/// A `Codable` snapshot pairing a worker id with its loop state (issue #34).
///
/// The loop's configuration and full iteration history are restored exactly; the
/// live engine is not resumed. ``RegattaRestorePlanner`` maps a running loop's
/// status to a non-live status on restore (a loop whose worker process is gone
/// cannot keep iterating until relaunched).
public struct LoopSnapshot: Sendable, Equatable, Codable, Identifiable {
    /// The id of the worker this loop drives. Doubles as the snapshot identity so
    /// the persisted set is keyed one-loop-per-worker.
    public let workerID: String

    /// The persisted loop state: configuration, status, and iteration history.
    public let state: RegattaLoopState

    /// Stable identity for `Identifiable` (the worker id).
    public var id: String { workerID }

    /// Creates a loop snapshot.
    ///
    /// - Parameters:
    ///   - workerID: The id of the worker this loop drives.
    ///   - state: The loop state to persist.
    public init(workerID: String, state: RegattaLoopState) {
        self.workerID = workerID
        self.state = state
    }
}
