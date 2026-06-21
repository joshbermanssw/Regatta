import Foundation
import Observation
import RegattaCore

/// The view-model that projects the ``RegattaOrchestrator``'s live Fleet snapshots
/// into value-typed rows for the Fleet rail section.
///
/// ## Lifecycle
/// Create once as `@State` in ``RegattaRailView`` (defaulting to the shared
/// ``RegattaFleetManager`` orchestrator) and pass by reference into
/// ``FleetSectionView``. Call ``startObserving()`` when the section appears; it
/// subscribes to the orchestrator's `updates()` stream and mirrors every snapshot
/// onto `@MainActor`.
///
/// ## Concurrency
/// `@MainActor @Observable` — `workers` is read directly by SwiftUI. The
/// orchestrator is an `actor` reached only through `await` inside the observation
/// `Task`.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// ``workers`` is a flat array of ``Worker`` value types. No orchestrator/actor
/// reference escapes the `ForEach` boundary in the view; rows get `Worker` copies
/// plus a cancel closure.
@MainActor
@Observable
final class RegattaFleetViewModel {

    // MARK: - Observable state

    /// The current Fleet snapshot in spawn order. Fed into `ForEach` rows as
    /// value copies.
    private(set) var workers: [Worker] = []

    // MARK: - Private non-observable

    /// The orchestrator that owns worker lifecycle. `@ObservationIgnored` — it is
    /// an internal resource handle, not UI-observable.
    @ObservationIgnored
    private let orchestrator: RegattaOrchestrator

    /// The structured `Task` consuming the orchestrator's snapshot stream.
    @ObservationIgnored
    private var observeTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a view-model bound to the given orchestrator.
    ///
    /// - Parameter orchestrator: The orchestrator to observe. Defaults to the
    ///   app-lifetime instance from ``RegattaFleetManager``.
    init(orchestrator: RegattaOrchestrator? = nil) {
        self.orchestrator = orchestrator ?? RegattaFleetManager.shared.orchestrator
    }

    // MARK: - Lifecycle

    /// Subscribes to the orchestrator's Fleet snapshots. Safe to call repeatedly;
    /// only the first call starts an observation task.
    func startObserving() {
        guard observeTask == nil else { return }
        observeTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in await self.orchestrator.updates() {
                if Task.isCancelled { break }
                self.workers = snapshot
            }
        }
    }

    /// Cancels the observation task. Idempotent.
    func stopObserving() {
        observeTask?.cancel()
        observeTask = nil
    }

    // MARK: - Actions

    /// Requests a new worker from the orchestrator (the brain→Fleet spawn path).
    ///
    /// - Parameter spec: The worker request (goal/prompt, repo, agent launch).
    @discardableResult
    func spawnWorker(_ spec: WorkerSpec) async -> UUID {
        await orchestrator.spawnWorker(spec)
    }

    /// Cancels a worker from the Fleet list.
    ///
    /// - Parameter id: The worker to cancel.
    func cancelWorker(_ id: UUID) {
        Task { try? await orchestrator.cancelWorker(id) }
    }
}
