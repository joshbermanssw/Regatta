import Foundation
import Observation
import RegattaFleet

/// The view-model that projects the ``Fleet``'s shepherd list into the Fleet
/// rail section and drives the "hand to Regatta" action.
///
/// ## Lifecycle
/// Create once as `@State` in ``RegattaRailView``; call ``observe()`` on appear
/// to begin consuming the Fleet's snapshot stream.
///
/// ## Concurrency
/// `@MainActor @Observable` — all published state is read directly by SwiftUI.
/// The actor-isolated ``Fleet`` is touched only through `await` calls inside
/// structured `Task`s owned by this class.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// ``shepherds`` is a flat array of ``ShepherdState`` value types. No `Fleet`
/// reference escapes the `ForEach` boundary in the view layer.
@MainActor
@Observable
final class RegattaFleetViewModel {

    // MARK: - Observable state

    /// The current persistent shepherds, ordered for stable rendering.
    /// Value snapshots only — safe to feed into list rows directly.
    private(set) var shepherds: [ShepherdState] = []

    /// The actions awaiting the user's approve/reject decision (staged mode),
    /// across all shepherds. Value snapshots only.
    private(set) var pendingActions: [PendingAction] = []

    // MARK: - Private non-observable

    /// The app-lifetime Fleet. `@ObservationIgnored` — a resource handle, not
    /// a UI-observable property.
    @ObservationIgnored
    private let fleet: Fleet

    /// The task consuming the Fleet's snapshot stream.
    @ObservationIgnored
    private var observeTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a view-model backed by the given Fleet.
    ///
    /// - Parameter fleet: The ``Fleet`` to observe and hand PRs off to. Defaults
    ///   to the app-lifetime Fleet from ``RegattaFleetManager``.
    init(fleet: Fleet? = nil) {
        self.fleet = fleet ?? RegattaFleetManager.shared.fleet
    }

    // MARK: - Public API

    /// The task consuming the autonomy gate's pending-action stream.
    @ObservationIgnored
    private var pendingTask: Task<Void, Never>?

    /// Begins consuming the Fleet's snapshot stream and the autonomy gate's
    /// pending-action stream. Idempotent.
    func observe() {
        guard observeTask == nil else { return }
        observeTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.fleet.snapshots()
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                self.shepherds = snapshot
            }
        }
        pendingTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.fleet.autonomyGate.pendingActions()
            for await actions in stream {
                guard !Task.isCancelled else { break }
                self.pendingActions = actions
            }
        }
    }

    /// Sets a PR's autonomy mode. Per-PR; changeable at any time.
    func setAutonomyMode(_ mode: AutonomyMode, for pullRequest: PullRequestRef) {
        Task { await fleet.setAutonomyMode(mode, for: pullRequest) }
    }

    /// Approves a pending action (executes it through the gate's executor).
    func approve(_ id: UUID) {
        Task { await fleet.autonomyGate.approve(id) }
    }

    /// Rejects a pending action (drops it without executing).
    func reject(_ id: UUID) {
        Task { await fleet.autonomyGate.reject(id) }
    }

    /// Hands a pull request off to the Fleet, creating a persistent shepherd and
    /// starting its poll loop. Idempotent on PR identity — a repeat handoff does
    /// not create a duplicate.
    ///
    /// - Parameter pullRequest: The PR to shepherd.
    func handoff(_ pullRequest: PullRequestRef) {
        Task { await fleet.handoff(pullRequest) }
    }

    /// Removes the shepherd for the given PR, if present.
    func dismiss(_ pullRequest: PullRequestRef) {
        Task { await fleet.dismiss(pullRequest) }
    }

    /// Stops observing and releases the consuming tasks. Idempotent.
    func shutdown() {
        observeTask?.cancel()
        observeTask = nil
        pendingTask?.cancel()
        pendingTask = nil
    }
}
