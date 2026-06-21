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
/// The orchestrator is constructed with the real ``ProcessPaneBridge`` (issue
/// #14): it spawns each worker's agent as a subprocess in its provisioned
/// worktree and streams stdout/stderr/termination back through the
/// ``PaneBridge`` seam.
@MainActor
final class RegattaFleetManager {

    /// Shared instance accessed by the Fleet rail and the brain spawn path.
    static let shared = RegattaFleetManager()

    /// The app-lifetime orchestrator that provisions worktrees and launches workers.
    let orchestrator: RegattaOrchestrator

    private init() {
        orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(
                baseDirectory: RegattaWorktreeManager.defaultBaseDirectory()
            ),
            paneBridge: ProcessPaneBridge()
        )
    }
}
