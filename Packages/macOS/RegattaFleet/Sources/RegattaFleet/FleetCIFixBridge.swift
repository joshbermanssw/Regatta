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
    ///
    /// As well as feeding each shepherd state to the reactor, the bridge routes the
    /// loop's *terminal outcome* back onto the Fleet so the shepherd card reflects
    /// what happened: a give-up (cap hit or no code-level fix found) raises the
    /// needs-attention banner with a reason naming the still-failing checks; a green
    /// recovery clears any stale banner. This is the "make the outcome legible"
    /// half — without it the loop could give up while the card still said "CI
    /// failing", leaving the user unable to tell whether it gave up or is still
    /// working.
    public func start() {
        guard pump == nil else { return }
        pump = Task { [fleet, reactor] in
            let stream = await fleet.snapshots()
            for await snapshot in stream {
                for state in snapshot {
                    let outcome = await reactor.ingest(state)
                    await Self.reflect(outcome, for: state, on: fleet)
                }
            }
        }
    }

    /// Reflects a finished loop's outcome onto the Fleet's per-PR needs-attention
    /// flag. Only acts when an `ingest` actually ran a loop (non-`nil` outcome);
    /// a `nil` outcome means no loop ran for this snapshot, so the existing flag is
    /// left untouched.
    private static func reflect(
        _ outcome: CIFixOutcome?,
        for state: ShepherdState,
        on fleet: Fleet
    ) async {
        guard let outcome else { return }
        switch outcome {
        case let .needsAttention(reason):
            // The loop gave up without making CI green — raise the banner with the
            // reason that names the still-failing checks.
            await fleet.setNeedsAttention(reason, for: state.pullRequest)
        case .greenSuccess:
            // CI recovered — clear any stale needs-attention banner.
            await fleet.setNeedsAttention(nil, for: state.pullRequest)
        case .cancelled:
            // A deliberate cancel is not a give-up; leave the flag as-is.
            break
        }
    }

    /// Stops forwarding. Idempotent.
    public func stop() {
        pump?.cancel()
        pump = nil
    }
}
