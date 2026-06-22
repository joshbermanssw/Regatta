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

    /// The toast center for spawn/cancel/remove feedback.
    @ObservationIgnored
    private let toasts: RegattaToastCenter

    /// Supplies the active workspace tab's context so the spawn form can default its
    /// repository to the repo the user is actually working in (rather than `/`).
    /// `@MainActor`-isolated and invoked only from a button action, never `body`.
    @ObservationIgnored
    private var contextProvider: (@MainActor () -> AttachedTabContext?)?

    // MARK: - Init

    /// Creates a Summon overlay view-model.
    ///
    /// - Parameters:
    ///   - orchestrator: The orchestrator to observe and spawn against. Defaults
    ///     to the app-lifetime instance from ``RegattaFleetManager``.
    ///   - spawnSpecProvider: Builds the ``WorkerSpec`` for the spawn tile.
    ///     Defaults to ``RegattaSummonViewModel/defaultSpawnSpec()``.
    ///   - toasts: The toast center for action feedback. Defaults to the shared
    ///     app-lifetime instance.
    init(
        orchestrator: RegattaOrchestrator? = nil,
        spawnSpecProvider: (@MainActor () -> WorkerSpec)? = nil,
        toasts: RegattaToastCenter = .shared
    ) {
        self.orchestrator = orchestrator ?? RegattaFleetManager.shared.orchestrator
        self.spawnSpecProvider = spawnSpecProvider ?? RegattaSummonViewModel.defaultSpawnSpec
        self.toasts = toasts
    }

    // MARK: - Context wiring

    /// Records the active-tab context provider used to default the spawn form's
    /// repository. Called by the Fleet rail when it triggers a summon, so the
    /// window-hosted overlay can reach the same context the rail sees.
    func setContextProvider(_ provider: (@MainActor () -> AttachedTabContext?)?) {
        self.contextProvider = provider
    }

    /// Builds a fresh ``RegattaSpawnFormViewModel`` for the spawn form, seeded with
    /// the active tab's working directory (via ``contextProvider``) as the default
    /// repository and spawning through the same orchestrator the overlay observes.
    func makeSpawnFormViewModel() -> RegattaSpawnFormViewModel {
        let directory = contextProvider?()?.currentDirectory
        let orchestrator = self.orchestrator
        return RegattaSpawnFormViewModel(
            contextDirectory: directory,
            toasts: toasts,
            spawn: { spec in
                Task { _ = await orchestrator.spawnWorker(spec) }
            }
        )
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

    /// Spawns a worker directly from ``spawnSpecProvider`` (the placeholder
    /// ``defaultSpawnSpec()``) via the orchestrator, emitting a success toast.
    ///
    /// This is the **last-resort fallback** path. The `+ spawn worker` tile now
    /// opens the ``RegattaSpawnFormView`` sheet (via ``makeSpawnFormViewModel()``)
    /// so the user picks a real repository and task; this method is retained only
    /// for the placeholder spec and is not invoked from the tile.
    func spawnWorker() {
        let spec = spawnSpecProvider()
        Task { [weak self] in
            guard let self else { return }
            _ = await self.orchestrator.spawnWorker(spec)
            self.toasts.success(
                String(localized: "regatta.toast.worker.spawned.title", defaultValue: "Worker spawned"),
                spec.name
            )
        }
    }

    /// Cancels a worker shown in the overlay grid. Emits a toast on success/failure.
    ///
    /// - Parameter id: The worker to cancel.
    func cancelWorker(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.orchestrator.cancelWorker(id)
                self.toasts.info(
                    String(localized: "regatta.toast.worker.cancelled.title", defaultValue: "Worker cancelled")
                )
            } catch {
                self.toasts.error(
                    String(localized: "regatta.toast.worker.cancelFailed.title", defaultValue: "Couldn't cancel worker")
                )
            }
        }
    }

    /// Removes a worker from the grid entirely (cancelling first if still running),
    /// so finished or failed workers can be cleared. Emits a toast.
    ///
    /// - Parameter id: The worker to remove.
    func removeWorker(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            await self.orchestrator.removeWorker(id)
            self.toasts.info(
                String(localized: "regatta.toast.worker.removed.title", defaultValue: "Worker removed")
            )
        }
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
