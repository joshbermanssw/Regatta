import Foundation
import RegattaCore

/// A thin `@MainActor` seam that holds the app-lifetime ``RegattaOrchestrator`` so
/// that the brain, the Fleet rail, and `AppDelegate` teardown all share a single
/// orchestrator instance.
///
/// Design note: a singleton is warranted here for the same reason as
/// ``RegattaBrainManager`` / ``RegattaMemoryManager`` — the composition root
/// (`AppDelegate`), the brain, and the SwiftUI view tree all need the *same*
/// orchestrator and there is no other injection path between them. The singleton
/// holds no logic beyond constructing the object graph once.
///
/// ## Pane Bridge dependency (#14)
/// The orchestrator is constructed with ``UnavailablePaneBridge`` until the real
/// Pane Bridge (issue #14) lands. Swapping in `ProcessPaneBridge()` here is the
/// only wiring change needed once #14 merges — everything above the
/// ``PaneBridge`` seam is already complete.
@MainActor
final class RegattaFleetManager {

    /// Shared instance accessed by the Fleet rail and the brain spawn path.
    static let shared = RegattaFleetManager()

    /// The app-lifetime orchestrator that provisions worktrees and launches workers.
    let orchestrator: RegattaOrchestrator

    private let defaults: UserDefaults
    private var defaultsObserver: NSObjectProtocol?

    private init() {
        self.defaults = .standard
        let cap = RegattaConcurrencySettings(defaults: defaults).maxConcurrentWorkers
        // TODO(#14): replace `UnavailablePaneBridge()` with `ProcessPaneBridge()`
        // once the Pane Bridge lands.
        orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(
                baseDirectory: RegattaWorktreeManager.defaultBaseDirectory()
            ),
            paneBridge: UnavailablePaneBridge(),
            maxConcurrentWorkers: cap
        )
        observeConcurrencyCap()
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
