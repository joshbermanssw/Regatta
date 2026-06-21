import AppKit
import Foundation

/// Session-restore entry point for Regatta (issue #34, state persistence +
/// session restore).
///
/// `AppDelegate` is the composition root, so it owns the one-shot launch restore:
/// it loads the persisted snapshot (with restore semantics already applied —
/// live workers mapped to `interrupted`, running loops re-armed, worktree
/// assignments reconciled against disk) and resumes the persisted PR shepherds
/// into the live Fleet, which auto-starts their polling.
///
/// Workers are intentionally **not** relaunched here: their live agent processes
/// cannot be resumed, so they are surfaced as `interrupted` for the user to
/// relaunch from the Fleet. PR shepherds, being event-driven pollers, resume
/// automatically.
extension AppDelegate {

    /// Loads restored Regatta state and resumes PR shepherds. Safe no-op when no
    /// persisted state exists or the store could not be opened.
    func restoreRegattaSessionOnLaunch() {
        Task { @MainActor in
            guard let snapshot = await RegattaPersistenceManager.shared.loadRestoredSnapshot() else {
                return
            }
            await RegattaFleetManager.shared.resumeShepherds(from: snapshot)
        }
    }
}
