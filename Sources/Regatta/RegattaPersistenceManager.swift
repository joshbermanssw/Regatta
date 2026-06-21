import Foundation
import RegattaPersistence

/// A thin `@MainActor` seam that holds the app-lifetime ``RegattaStateStore`` and
/// exposes the restore helpers, so the rail/fleet UI and `AppDelegate` share one
/// instance (issue #34, state persistence + session restore).
///
/// The store is created once under the same `~/Library/Application Support/Regatta`
/// directory that `RegattaMemory` and `RegattaWorktreeManager` use. If that
/// directory cannot be created, ``store`` is `nil` and persistence degrades
/// gracefully (the app still runs; nothing is saved or restored).
///
/// Design note: a singleton is warranted for the same reason as
/// ``RegattaMemoryManager`` — `AppDelegate` (the composition root) and the
/// SwiftUI view tree both need the same store and there is no other injection
/// path between them. The seam holds no business logic; the restore *rules* live
/// in the testable ``RegattaPersistence`` package types it vends.
@MainActor
final class RegattaPersistenceManager {

    // MARK: - Shared instance

    /// Shared instance accessed by the rail/fleet UI and `AppDelegate`.
    static let shared = RegattaPersistenceManager()

    // MARK: - Store

    /// The shared ``RegattaStateStore``, or `nil` if the backing directory could
    /// not be created.
    let store: RegattaStateStore?

    /// The pure restore-semantics planner (workers → interrupted, loops re-armed).
    let restorePlanner = RegattaRestorePlanner()

    /// The worktree reconciler that drops assignments whose directory is gone.
    let worktreeReconciler = RegattaWorktreeReconciler()

    // MARK: - Init

    private init() {
        store = try? RegattaStateStore(baseDirectory: RegattaStateStore.defaultBaseDirectory())
    }

    // MARK: - Restore

    /// Loads the persisted snapshot and applies restore semantics.
    ///
    /// Workers that were live become `interrupted`; running loops are re-armed to
    /// idle while keeping their history; worktree assignments are reconciled
    /// against disk. PR shepherds are resumed separately via
    /// ``RegattaShepherdResumer`` (they need a live poller injected at the call
    /// site). Returns `nil` if no store is available.
    func loadRestoredSnapshot() async -> RegattaStateSnapshot? {
        guard let store else { return nil }
        let persisted = await store.currentSnapshot()
        let workers = restorePlanner.restoredWorkers(from: persisted)
        let loops = restorePlanner.restoredLoops(from: persisted)
        let worktrees = worktreeReconciler.reconcile(persisted.worktrees).kept
        return RegattaStateSnapshot(
            workers: workers,
            loops: loops,
            shepherds: persisted.shepherds,
            autonomyModes: persisted.autonomyModes,
            worktrees: worktrees
        )
    }
}
