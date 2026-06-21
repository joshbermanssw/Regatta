import Foundation

/// Connects a ``Fleet``'s shepherd snapshots to a ``CIFixReactor`` without
/// touching the Fleet's internals.
///
/// This is the issue-#30 wiring hook. Rather than reaching into ``Fleet`` (whose
/// core stays owned by #29), the bridge subscribes to the Fleet's public
/// `snapshots()` stream and forwards each shepherd state to the reactor. The
/// reactor's own transition + in-flight guards ensure a single CI failure spawns
/// a single fix loop.
///
/// ## Concurrency
/// `actor` — owns the forwarding `Task` and cancels it on ``stop()``. The
/// composition root constructs one bridge per Fleet/reactor pair and retains it
/// for the app's lifetime.
public actor FleetCIFixBridge {
    private let fleet: Fleet
    private let reactor: CIFixReactor
    private var pump: Task<Void, Never>?

    /// Creates a bridge between a Fleet and a CI-fix reactor.
    ///
    /// - Parameters:
    ///   - fleet: The Fleet whose shepherd snapshots are observed.
    ///   - reactor: The reactor that reacts to failing checks.
    public init(fleet: Fleet, reactor: CIFixReactor) {
        self.fleet = fleet
        self.reactor = reactor
    }

    /// Begins forwarding shepherd snapshots to the reactor. Idempotent.
    public func start() {
        guard pump == nil else { return }
        pump = Task { [fleet, reactor] in
            let stream = await fleet.snapshots()
            for await snapshot in stream {
                for state in snapshot {
                    await reactor.ingest(state)
                }
            }
        }
    }

    /// Stops forwarding. Idempotent.
    public func stop() {
        pump?.cancel()
        pump = nil
    }
}
