import Foundation
import Observation
import RegattaCore

/// Drives the Summon overlay (issue #17): a grid that fills the main work area
/// with the Fleet's live worker terminals plus a `+ spawn worker` tile, dismissed
/// with `esc`.
///
/// ## Composition
/// The pure grid composition and the present/dismiss state machine live in
/// ``RegattaCore`` (``SummonGrid`` / ``SummonPresentation``) and are unit-tested
/// there. This `@MainActor @Observable` view-model is the thin app-side adapter:
/// it observes the orchestrator's `updates()` snapshot stream, rebuilds the
/// ``SummonGrid`` on each snapshot, and exposes the presentation flag + intents to
/// the SwiftUI overlay.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// The overlay grid feeds `ForEach` from ``grid``'s value-typed ``SummonTile``
/// array. No orchestrator/actor reference crosses into the grid cells; cells get
/// `Worker` value snapshots plus closures.
///
/// ## Live-surface seam (#14/#16)
/// A worker's live terminal surface is resolved from its pane handle, which the
/// ``Worker`` snapshot does not yet expose (the orchestrator keeps `paneID`
/// private and the production `PaneBridge` is #14). Until that handle is exposed,
/// each worker cell renders a seam placeholder; the grid layout, dismiss, and
/// spawn paths are complete.
@MainActor
@Observable
final class RegattaSummonViewModel {

    // MARK: - Observable state

    /// The current overlay grid, rebuilt from each Fleet snapshot.
    private(set) var grid: SummonGrid = SummonGrid(workers: [])

    /// Whether the overlay is filling the main work area.
    var isPresented: Bool { presentation.isPresented }

    // MARK: - Private non-observable

    /// The present/dismiss state machine (pure, from RegattaCore).
    private var presentation = SummonPresentation()

    /// The orchestrator that owns worker lifecycle. `@ObservationIgnored` — an
    /// internal resource handle, not UI-observable.
    @ObservationIgnored
    private let orchestrator: RegattaOrchestrator

    /// Builds the default ``WorkerSpec`` used by the `+ spawn worker` tile.
    @ObservationIgnored
    private let spawnSpecProvider: @MainActor () -> WorkerSpec

    /// The task consuming the orchestrator's snapshot stream.
    @ObservationIgnored
    private var observeTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a Summon overlay view-model.
    ///
    /// - Parameters:
    ///   - orchestrator: The orchestrator to observe and spawn against. Defaults
    ///     to the app-lifetime instance from ``RegattaFleetManager``.
    ///   - spawnSpecProvider: Builds the ``WorkerSpec`` for the spawn tile.
    ///     Defaults to ``RegattaSummonViewModel/defaultSpawnSpec()``.
    init(
        orchestrator: RegattaOrchestrator? = nil,
        spawnSpecProvider: (@MainActor () -> WorkerSpec)? = nil
    ) {
        self.orchestrator = orchestrator ?? RegattaFleetManager.shared.orchestrator
        self.spawnSpecProvider = spawnSpecProvider ?? RegattaSummonViewModel.defaultSpawnSpec
    }

    // MARK: - Lifecycle

    /// Subscribes to the orchestrator's Fleet snapshots and rebuilds ``grid`` on
    /// each. Safe to call repeatedly; only the first call starts a task.
    func startObserving() {
        guard observeTask == nil else { return }
        observeTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in await self.orchestrator.updates() {
                if Task.isCancelled { break }
                self.grid = SummonGrid(workers: snapshot)
            }
        }
    }

    /// Cancels the snapshot observation task. Idempotent.
    func stopObserving() {
        observeTask?.cancel()
        observeTask = nil
    }

    // MARK: - Presentation intents

    /// Shows the overlay grid (Fleet click / expand control).
    func summon() {
        presentation.summon()
    }

    /// Hides the overlay grid, leaving the underlying work untouched. Bound to `esc`.
    func dismiss() {
        presentation.dismiss()
    }

    /// Toggles the overlay.
    func toggle() {
        presentation.toggle()
    }

    // MARK: - Spawn intent

    /// Spawns a new worker from the `+ spawn worker` tile via the orchestrator.
    func spawnWorker() {
        let spec = spawnSpecProvider()
        Task { await orchestrator.spawnWorker(spec) }
    }

    /// Cancels a worker shown in the overlay grid.
    ///
    /// - Parameter id: The worker to cancel.
    func cancelWorker(_ id: UUID) {
        Task { try? await orchestrator.cancelWorker(id) }
    }

    // MARK: - Default spawn spec

    /// The default ``WorkerSpec`` used by the spawn tile: a `claude` agent run in
    /// the current working directory's repository.
    ///
    /// This is a placeholder until the brain/Fleet provide a richer spawn form; it
    /// is sufficient to exercise the orchestrator spawn path. Once the production
    /// Pane Bridge (#14) is wired, spawned workers launch a real agent.
    static func defaultSpawnSpec() -> WorkerSpec {
        let repoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return WorkerSpec(
            name: String(
                localized: "regatta.summon.newWorker.name",
                defaultValue: "New worker"
            ),
            prompt: "",
            repoURL: repoURL,
            agentLaunch: WorkerAgentLaunch(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["claude"],
                appendPrompt: false
            )
        )
    }
}
