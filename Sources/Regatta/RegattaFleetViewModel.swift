import Foundation
import Observation
import RegattaCore
import RegattaFleet

/// The view-model behind the Fleet rail section.
///
/// It projects two live sources into value-typed state for the section:
/// - the ``RegattaOrchestrator``'s ephemeral brain-spawned ``Worker`` list, and
/// - the ``Fleet``'s persistent PR shepherds plus the autonomy gate's pending
///   approvals and per-PR activity log / fix-loop status.
///
/// ## Lifecycle
/// Create once as `@State` in ``RegattaRailView`` (defaulting to the shared
/// ``RegattaFleetManager``) and pass by reference into ``FleetSectionView``. Call
/// ``observe()`` when the section appears.
///
/// ## Concurrency
/// `@MainActor @Observable` — every published property is read directly by
/// SwiftUI. The actor-isolated ``RegattaOrchestrator`` / ``Fleet`` /
/// ``AutonomyGate`` are reached only through `await` inside structured `Task`s.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// ``workers`` and ``shepherds`` are flat arrays of value types. No
/// orchestrator/`Fleet`/actor reference escapes the `ForEach` boundary; rows get
/// value copies plus closures only.
@MainActor
@Observable
final class RegattaFleetViewModel {

    // MARK: - Observable state (orchestrator workers)

    /// The current orchestrator Fleet snapshot in spawn order. Fed into rows as
    /// value copies.
    private(set) var workers: [Worker] = []

    // MARK: - Observable state (PR shepherds)

    /// The current persistent shepherds, ordered for stable rendering.
    private(set) var shepherds: [ShepherdState] = []

    /// The actions awaiting the user's approve/reject decision (staged mode),
    /// across all shepherds.
    private(set) var pendingActions: [PendingAction] = []

    /// The activity log per PR, keyed by ``PullRequestRef/id``. Drives the card's
    /// activity-log section (#33).
    private(set) var activityLog: [String: [ShepherdActivityEntry]] = [:]

    /// The active CI-fix loop per PR, keyed by ``PullRequestRef/id``. `nil` when
    /// no loop is running. Drives the card's fix-loop banner (#33).
    private(set) var fixLoops: [String: ShepherdFixLoopStatus] = [:]

    // MARK: - Private non-observable

    /// The orchestrator that owns ephemeral worker lifecycle.
    @ObservationIgnored
    private let orchestrator: RegattaOrchestrator

    /// The app-lifetime Fleet that owns persistent PR shepherds.
    @ObservationIgnored
    private let fleet: Fleet

    @ObservationIgnored
    private var workerTask: Task<Void, Never>?
    @ObservationIgnored
    private var shepherdTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a view-model bound to the given orchestrator and Fleet.
    ///
    /// - Parameters:
    ///   - orchestrator: The orchestrator to observe. Defaults to the app-lifetime
    ///     instance from ``RegattaFleetManager``.
    ///   - fleet: The Fleet to observe and hand PRs off to. Defaults to the
    ///     app-lifetime instance from ``RegattaFleetManager``.
    init(orchestrator: RegattaOrchestrator? = nil, fleet: Fleet? = nil) {
        self.orchestrator = orchestrator ?? RegattaFleetManager.shared.orchestrator
        self.fleet = fleet ?? RegattaFleetManager.shared.fleet
    }

    // MARK: - Lifecycle

    /// Subscribes to the orchestrator's worker snapshots, the Fleet's shepherd
    /// snapshots, and the autonomy gate's pending-action stream. Idempotent.
    func observe() {
        if workerTask == nil {
            workerTask = Task { [weak self] in
                guard let self else { return }
                for await snapshot in await self.orchestrator.updates() {
                    if Task.isCancelled { break }
                    self.workers = snapshot
                }
            }
        }
        if shepherdTask == nil {
            shepherdTask = Task { [weak self] in
                guard let self else { return }
                let stream = await self.fleet.snapshots()
                for await snapshot in stream {
                    if Task.isCancelled { break }
                    self.shepherds = snapshot
                }
            }
        }
        if pendingTask == nil {
            pendingTask = Task { [weak self] in
                guard let self else { return }
                let stream = await self.fleet.autonomyGate.pendingActions()
                for await actions in stream {
                    if Task.isCancelled { break }
                    self.pendingActions = actions
                }
            }
        }
    }

    /// Compatibility alias for the orchestrator-era observation entry point.
    func startObserving() { observe() }

    /// Cancels all observation tasks. Idempotent.
    func shutdown() {
        workerTask?.cancel(); workerTask = nil
        shepherdTask?.cancel(); shepherdTask = nil
        pendingTask?.cancel(); pendingTask = nil
    }

    /// Compatibility alias for the orchestrator-era teardown entry point.
    func stopObserving() { shutdown() }

    // MARK: - Worker actions

    /// Requests a new worker from the orchestrator (the brain→Fleet spawn path).
    @discardableResult
    func spawnWorker(_ spec: WorkerSpec) async -> UUID {
        await orchestrator.spawnWorker(spec)
    }

    /// Cancels a worker from the Fleet list.
    func cancelWorker(_ id: UUID) {
        Task { try? await orchestrator.cancelWorker(id) }
    }

    // MARK: - Shepherd actions

    /// Hands a pull request off to the Fleet, creating a persistent shepherd and
    /// starting its poll loop. Idempotent on PR identity.
    func handoff(_ pullRequest: PullRequestRef) {
        Task { await fleet.handoff(pullRequest) }
    }

    /// Removes the shepherd for the given PR, if present, and clears its local
    /// card state (activity log + fix loop).
    func dismiss(_ pullRequest: PullRequestRef) {
        activityLog[pullRequest.id] = nil
        fixLoops[pullRequest.id] = nil
        Task { await fleet.dismiss(pullRequest) }
    }

    /// Sets a PR's autonomy mode. Per-PR; changeable at any time.
    func setAutonomyMode(_ mode: AutonomyMode, for pullRequest: PullRequestRef) {
        Task { await fleet.setAutonomyMode(mode, for: pullRequest) }
    }

    /// Approves a pending action (executes it through the gate's executor) and
    /// records the outcome in the activity log.
    func approve(_ id: UUID) {
        let action = pendingActions.first { $0.id == id }
        Task { [weak self] in
            guard let self else { return }
            let resolved = await self.fleet.autonomyGate.approve(id)
            guard let action else { return }
            let succeeded = resolved?.status == .completed
            let summary = succeeded
                ? String(format: String(localized: "fleet.activity.approved", defaultValue: "Approved: %@"), action.summary)
                : String(format: String(localized: "fleet.activity.failed", defaultValue: "Failed: %@"), action.summary)
            self.recordActivity(
                ShepherdActivityEntry(kind: self.activityKind(for: action.kind), summary: summary),
                for: action.pullRequest
            )
        }
    }

    /// Rejects a pending action (drops it without executing) and records it.
    func reject(_ id: UUID) {
        let action = pendingActions.first { $0.id == id }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.fleet.autonomyGate.reject(id)
            guard let action else { return }
            self.recordActivity(
                ShepherdActivityEntry(
                    kind: self.activityKind(for: action.kind),
                    summary: String(format: String(localized: "fleet.activity.rejected", defaultValue: "Rejected: %@"), action.summary)
                ),
                for: action.pullRequest
            )
        }
    }

    // MARK: - Per-PR projection reads

    /// The activity log for one PR.
    func activity(for pullRequest: PullRequestRef) -> [ShepherdActivityEntry] {
        activityLog[pullRequest.id] ?? []
    }

    /// The active fix loop for one PR, or `nil`.
    func fixLoop(for pullRequest: PullRequestRef) -> ShepherdFixLoopStatus? {
        fixLoops[pullRequest.id]
    }

    // MARK: - Activity / fix-loop seam (#30 / #31)

    /// Appends an activity-log entry for a PR, capped to a recent window.
    func recordActivity(_ entry: ShepherdActivityEntry, for pullRequest: PullRequestRef) {
        var entries = activityLog[pullRequest.id] ?? []
        entries.append(entry)
        if entries.count > Self.maxActivityEntries {
            entries.removeFirst(entries.count - Self.maxActivityEntries)
        }
        activityLog[pullRequest.id] = entries
    }

    /// Sets (or clears, with `nil`) the active fix loop for a PR.
    func setFixLoop(_ status: ShepherdFixLoopStatus?, for pullRequest: PullRequestRef) {
        fixLoops[pullRequest.id] = status
    }

    /// Maps an outward ``ActionKind`` to an activity-log kind.
    private func activityKind(for kind: ActionKind) -> ShepherdActivityEntry.Kind {
        switch kind {
        case .push: return .push
        case .reply: return .reply
        case .resolve: return .resolve
        }
    }

    /// The maximum number of activity entries retained per PR.
    private static let maxActivityEntries = 50
}
