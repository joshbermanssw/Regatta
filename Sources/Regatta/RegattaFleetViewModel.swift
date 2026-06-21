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

    /// The activity log per PR, keyed by ``PullRequestRef/id``. Value snapshots
    /// only. Drives the card's activity-log section (#33).
    ///
    /// ## Seam for #30 / #31
    /// This base populates the log from the autonomy gate's approve/reject
    /// transitions. #30 (ci-fix loop) and #31 (reply/resolve) call
    /// ``recordActivity(_:for:)`` to add their own entries when they merge.
    private(set) var activityLog: [String: [ShepherdActivityEntry]] = [:]

    /// The active CI-fix loop per PR, keyed by ``PullRequestRef/id``. `nil` when
    /// no loop is running. Drives the card's fix-loop banner (#33).
    ///
    /// ## Seam for #30
    /// This base never starts a loop, so every slot stays `nil` and the banner
    /// is hidden. #30 drives this through ``setFixLoop(_:for:)`` when it lands.
    private(set) var fixLoops: [String: ShepherdFixLoopStatus] = [:]

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

    /// Approves a pending action (executes it through the gate's executor) and
    /// records the outcome in the activity log.
    func approve(_ id: UUID) {
        let action = pendingActions.first { $0.id == id }
        Task { [weak self] in
            guard let self else { return }
            let resolved = await self.fleet.autonomyGate.approve(id)
            guard let action = action else { return }
            let succeeded = resolved?.status == .completed
            let summary = succeeded
                ? String(
                    format: String(localized: "fleet.activity.approved", defaultValue: "Approved: %@"),
                    action.summary
                )
                : String(
                    format: String(localized: "fleet.activity.failed", defaultValue: "Failed: %@"),
                    action.summary
                )
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
            guard let action = action else { return }
            self.recordActivity(
                ShepherdActivityEntry(
                    kind: self.activityKind(for: action.kind),
                    summary: String(
                        format: String(localized: "fleet.activity.rejected", defaultValue: "Rejected: %@"),
                        action.summary
                    )
                ),
                for: action.pullRequest
            )
        }
    }

    // MARK: - Per-PR projection reads

    /// The activity log for one PR, newest-first ordering handled by the card.
    func activity(for pullRequest: PullRequestRef) -> [ShepherdActivityEntry] {
        activityLog[pullRequest.id] ?? []
    }

    /// The active fix loop for one PR, or `nil`.
    func fixLoop(for pullRequest: PullRequestRef) -> ShepherdFixLoopStatus? {
        fixLoops[pullRequest.id]
    }

    // MARK: - Activity / fix-loop seam (#30 / #31)

    /// Appends an activity-log entry for a PR. The card shows newest first.
    ///
    /// This is the seam #30 (ci-fix loop) and #31 (reply/resolve) call to record
    /// the actions they take once those branches merge. Entries are capped to a
    /// recent window so the log does not grow unbounded.
    func recordActivity(_ entry: ShepherdActivityEntry, for pullRequest: PullRequestRef) {
        var entries = activityLog[pullRequest.id] ?? []
        entries.append(entry)
        if entries.count > Self.maxActivityEntries {
            entries.removeFirst(entries.count - Self.maxActivityEntries)
        }
        activityLog[pullRequest.id] = entries
    }

    /// Sets (or clears, with `nil`) the active fix loop for a PR.
    ///
    /// This is the seam #30 drives when its ci-fix loop starts, succeeds, or
    /// gives up. This base never calls it, so the banner stays hidden.
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

    /// Hands a pull request off to the Fleet, creating a persistent shepherd and
    /// starting its poll loop. Idempotent on PR identity — a repeat handoff does
    /// not create a duplicate.
    ///
    /// - Parameter pullRequest: The PR to shepherd.
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

    /// Stops observing and releases the consuming tasks. Idempotent.
    func shutdown() {
        observeTask?.cancel()
        observeTask = nil
        pendingTask?.cancel()
        pendingTask = nil
    }
}
