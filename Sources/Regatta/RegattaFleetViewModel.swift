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

    /// The toast center every action emits success/error feedback into.
    @ObservationIgnored
    private let toasts: RegattaToastCenter

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
    ///   - toasts: The toast center for action feedback. Defaults to the shared
    ///     app-lifetime instance.
    init(
        orchestrator: RegattaOrchestrator? = nil,
        fleet: Fleet? = nil,
        toasts: RegattaToastCenter = .shared
    ) {
        self.orchestrator = orchestrator ?? RegattaFleetManager.shared.orchestrator
        self.fleet = fleet ?? RegattaFleetManager.shared.fleet
        self.toasts = toasts
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
    /// Emits a success toast naming the worker.
    @discardableResult
    func spawnWorker(_ spec: WorkerSpec) async -> UUID {
        let id = await orchestrator.spawnWorker(spec)
        toasts.success(
            String(localized: "regatta.toast.worker.spawned.title", defaultValue: "Worker spawned"),
            spec.name
        )
        return id
    }

    /// Cancels a worker from the Fleet list. Emits a toast on success/failure.
    func cancelWorker(_ id: UUID) {
        let name = workers.first { $0.id == id }?.name
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.orchestrator.cancelWorker(id)
                self.toasts.info(
                    String(localized: "regatta.toast.worker.cancelled.title", defaultValue: "Worker cancelled"),
                    name
                )
            } catch {
                self.toasts.error(
                    String(localized: "regatta.toast.worker.cancelFailed.title", defaultValue: "Couldn't cancel worker"),
                    name
                )
            }
        }
    }

    // MARK: - Shepherd actions

    /// Resolves the active workspace context to a PR and hands it off, always
    /// emitting a toast so the action is never a silent no-op (the handoff
    /// root-cause fix). Uses the `gh` branch→PR fallback when cmux's own PR
    /// detection is `nil`.
    ///
    /// This is the single shared handoff path; every entrypoint (the rail button
    /// today, plus any future command/menu) calls it with the same context closure.
    ///
    /// - Parameters:
    ///   - context: The active workspace context snapshot, or `nil`.
    ///   - resolver: The PR resolver (defaults to the production resolver).
    func handoffActiveTab(
        context: AttachedTabContext?,
        resolver: RegattaHandoffResolver = RegattaHandoffResolver()
    ) {
        Task { [weak self] in
            guard let self else { return }
            let resolution = await resolver.resolve(context: context)
            switch resolution {
            case .resolved(let ref):
                let isDuplicate = self.shepherds.contains { $0.pullRequest == ref }
                // Bug 1: record the active workspace's on-disk checkout so the
                // spawner runs this PR's workers against the real repo, not `/`.
                await self.fleet.handoff(ref, repositoryDirectory: Self.repositoryURL(from: context))
                if isDuplicate {
                    self.toasts.info(
                        String.localizedStringWithFormat(
                            String(localized: "fleet.handoff.toast.duplicate.title", defaultValue: "Already shepherding PR #%lld"),
                            ref.number
                        )
                    )
                } else {
                    self.toasts.success(
                        String.localizedStringWithFormat(
                            String(localized: "fleet.handoff.toast.success.title", defaultValue: "Handed PR #%lld to Regatta"),
                            ref.number
                        ),
                        String(localized: "fleet.handoff.toast.success.message", defaultValue: "Shepherd watching CI + reviews")
                    )
                }
            case .noContext:
                self.toasts.error(
                    String(localized: "fleet.handoff.toast.noContext.title", defaultValue: "No workspace selected"),
                    String(localized: "fleet.handoff.toast.noContext.message", defaultValue: "Open a git workspace to hand its PR off")
                )
            case .noPullRequest(let branch):
                self.toasts.error(
                    String(localized: "fleet.handoff.toast.noPR.title", defaultValue: "No pull request found"),
                    Self.noPullRequestMessage(branch: branch)
                )
            case .authFailure:
                self.toasts.error(
                    String(localized: "fleet.handoff.toast.auth.title", defaultValue: "GitHub CLI not authenticated"),
                    String(localized: "fleet.handoff.toast.auth.message", defaultValue: "Run gh auth login, then try again")
                )
            case .failure(let detail):
                self.toasts.error(
                    String(localized: "fleet.handoff.toast.failure.title", defaultValue: "Couldn't resolve the pull request"),
                    detail
                )
            }
        }
    }

    /// Hands an already-resolved pull request off to the Fleet, creating a
    /// persistent shepherd and starting its poll loop. Idempotent on PR identity.
    /// Used by session restore and tests; UI handoff goes through
    /// ``handoffActiveTab(context:resolver:)``.
    func handoff(_ pullRequest: PullRequestRef) {
        Task { await fleet.handoff(pullRequest) }
    }

    /// The on-disk checkout directory for a handoff context, or `nil` when the
    /// context is missing or carries no directory. Recorded with the handoff so
    /// the spawner runs the PR's workers against the real repo (Bug 1).
    private static func repositoryURL(from context: AttachedTabContext?) -> URL? {
        guard let directory = context?.currentDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !directory.isEmpty
        else { return nil }
        return URL(fileURLWithPath: directory)
    }

    /// The detail line for the no-PR error, naming the branch when known.
    private static func noPullRequestMessage(branch: String?) -> String {
        if let branch, !branch.isEmpty {
            return String.localizedStringWithFormat(
                String(localized: "fleet.handoff.toast.noPR.branch", defaultValue: "%@ has no open PR detected"),
                branch
            )
        }
        return String(localized: "fleet.handoff.toast.noPR.generic", defaultValue: "This branch has no open PR detected")
    }

    /// Removes the shepherd for the given PR, if present, and clears its local
    /// card state (activity log + fix loop). Emits a dismissal toast.
    func dismiss(_ pullRequest: PullRequestRef) {
        activityLog[pullRequest.id] = nil
        fixLoops[pullRequest.id] = nil
        Task { await fleet.dismiss(pullRequest) }
        toasts.info(
            String.localizedStringWithFormat(
                String(localized: "fleet.toast.dismissed.title", defaultValue: "Dismissed shepherd for PR #%lld"),
                pullRequest.number
            )
        )
    }

    /// Sets a PR's autonomy mode. Per-PR; changeable at any time. Emits a toast
    /// naming the new mode.
    func setAutonomyMode(_ mode: AutonomyMode, for pullRequest: PullRequestRef) {
        Task { await fleet.setAutonomyMode(mode, for: pullRequest) }
        toasts.info(
            String.localizedStringWithFormat(
                String(localized: "fleet.toast.autonomy.title", defaultValue: "Autonomy: %@"),
                Self.autonomyLabel(mode)
            ),
            String.localizedStringWithFormat(
                String(localized: "fleet.toast.autonomy.message", defaultValue: "PR #%lld"),
                pullRequest.number
            )
        )
    }

    /// A localized label for an autonomy mode, used in toasts.
    private static func autonomyLabel(_ mode: AutonomyMode) -> String {
        switch mode {
        case .staged:
            return String(localized: "fleet.toast.autonomy.staged", defaultValue: "Staged")
        case .auto:
            return String(localized: "fleet.toast.autonomy.auto", defaultValue: "Autonomous")
        }
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
            if succeeded {
                self.toasts.success(
                    String(localized: "fleet.toast.approved.title", defaultValue: "Action approved"),
                    action.summary
                )
            } else {
                self.toasts.error(
                    String(localized: "fleet.toast.approveFailed.title", defaultValue: "Action failed"),
                    action.summary
                )
            }
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
            self.toasts.info(
                String(localized: "fleet.toast.rejected.title", defaultValue: "Action rejected"),
                action.summary
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
