import Foundation
import RegattaCore
import RegattaFleet
import RegattaPersistence

/// A thin `@MainActor` seam holding the app-lifetime Fleet object graph so that
/// the brain, the Fleet rail, the handoff action, and `AppDelegate` teardown all
/// share a single ``RegattaOrchestrator`` and a single ``Fleet``.
///
/// The orchestrator owns ephemeral brain-spawned worker lifecycle; the Fleet owns
/// every long-lived PR shepherd watcher. Both need to be shared app-wide and
/// there is no other injection path between the composition root and the SwiftUI
/// view tree, so — like ``RegattaMemoryManager`` / ``RegattaBrainManager`` — a
/// singleton is warranted. The seam holds no domain logic beyond constructing the
/// object graph once and mirroring the concurrency cap into the orchestrator.
///
/// ## Pane Bridge dependency (#14)
/// The orchestrator is constructed with the real ``ProcessPaneBridge``: it spawns
/// each worker's agent as a subprocess in its provisioned worktree and streams
/// stdout/stderr/termination back through the ``PaneBridge`` seam.
@MainActor
final class RegattaFleetManager {

    /// Shared instance accessed by the rail view, the brain spawn path, and the
    /// handoff action.
    static let shared = RegattaFleetManager()

    /// The app-lifetime orchestrator that provisions worktrees and launches
    /// ephemeral workers.
    let orchestrator: RegattaOrchestrator

    /// The shared production ``Fleet`` (real `gh`-backed poller) that owns
    /// persistent PR shepherds.
    let fleet: Fleet

    private let defaults: UserDefaults
    private var defaultsObserver: NSObjectProtocol?

    private init() {
        self.defaults = .standard
        let cap = RegattaConcurrencySettings(defaults: defaults).maxConcurrentWorkers
        orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(
                baseDirectory: RegattaWorktreeManager.defaultBaseDirectory()
            ),
            paneBridge: ProcessPaneBridge(),
            maxConcurrentWorkers: cap
        )
        fleet = Fleet()
        observeConcurrencyCap()
    }

    /// Resumes persisted PR shepherds into the live Fleet on launch (issue #34).
    ///
    /// For each persisted shepherd snapshot, this re-hands-off the PR to the
    /// shared ``Fleet`` — which is idempotent on PR identity and auto-starts the
    /// watcher, so polling resumes automatically — and restores the PR's saved
    /// ``AutonomyMode``. PR shepherds are event-driven, so this fully restores
    /// them without resuming any process.
    ///
    /// - Parameter snapshot: The restored state snapshot from
    ///   ``RegattaPersistenceManager/loadRestoredSnapshot()``.
    func resumeShepherds(from snapshot: RegattaStateSnapshot) async {
        for shepherd in snapshot.shepherds {
            let pr = shepherd.pullRequest
            await fleet.handoff(pr)
            let mode = snapshot.autonomyModes[pr.id] ?? shepherd.autonomyMode
            await fleet.setAutonomyMode(mode, for: pr)
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    /// Mirrors live `regatta.maxConcurrentWorkers` config changes into the
    /// orchestrator so editing the cap in Settings (or `cmux.json`) takes effect
    /// without restarting — promoting queued workers when raised, holding new
    /// spawns when lowered. The settings file store applies the JSON value into
    /// `UserDefaults.standard`, which posts `didChangeNotification`.
    private func observeConcurrencyCap() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let cap = RegattaConcurrencySettings(defaults: self.defaults).maxConcurrentWorkers
            Task { [orchestrator] in
                await orchestrator.setMaxConcurrentWorkers(cap)
            }
        }
    }
}
