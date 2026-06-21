import Foundation

/// Connects a ``Fleet``'s shepherd snapshots to a ``ReviewThreadReactor`` without
/// touching the Fleet's internals.
///
/// This is the review-thread analogue of ``FleetCIFixBridge``. Rather than
/// reaching into ``Fleet``, the bridge subscribes to the Fleet's public
/// `snapshots()` stream and forwards each shepherd state to the reactor's
/// ``ReviewThreadReactor/react(to:)``. The reactor's own handled / in-flight
/// guards ensure each thread is addressed exactly once.
///
/// ## Concurrency
/// `actor` — owns the forwarding `Task` and cancels it on ``stop()``. The
/// composition root constructs one bridge per Fleet/reactor pair and retains it
/// for the app's lifetime.
public actor FleetReviewThreadBridge {
    private let fleet: Fleet
    private let reactor: ReviewThreadReactor
    private var pump: Task<Void, Never>?

    /// Creates a bridge between a Fleet and a review-thread reactor.
    ///
    /// - Parameters:
    ///   - fleet: The Fleet whose shepherd snapshots are observed.
    ///   - reactor: The reactor that addresses newly actionable review threads.
    public init(fleet: Fleet, reactor: ReviewThreadReactor) {
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
                    await reactor.react(to: state)
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
