public import Foundation
public import RegattaCore

/// The result of reconciling persisted worktree assignments against disk.
///
/// Splitting the outcome into kept and dropped sets lets callers both re-register
/// the live assignments with ``RegattaCore/RegattaWorktreeManager`` and surface
/// or log the ones that vanished while the app was not running.
public struct WorktreeReconciliation: Sendable, Equatable {
    /// Assignments whose worktree directory still exists on disk.
    public let kept: [WorktreeSnapshot]

    /// Assignments whose worktree directory is gone (deleted, moved, or never
    /// created). These are dropped from the restored state.
    public let dropped: [WorktreeSnapshot]

    /// Creates a reconciliation result.
    ///
    /// - Parameters:
    ///   - kept: Assignments still present on disk.
    ///   - dropped: Assignments no longer present on disk.
    public init(kept: [WorktreeSnapshot], dropped: [WorktreeSnapshot]) {
        self.kept = kept
        self.dropped = dropped
    }
}

/// Reconciles persisted worker→worktree assignments with what is actually on
/// disk (issue #34 acceptance criterion "worktree assignments are reconciled
/// with what's on disk").
///
/// A worktree directory may be gone after a restart — deleted by the user,
/// cleaned up by git, or never finished provisioning before the previous quit.
/// The reconciler keeps only assignments whose directory still exists and reports
/// the rest as dropped, so stale assignments never linger in restored state.
///
/// The filesystem check is injected via ``WorktreeExistenceChecking`` so the
/// reconciler is pure and unit-testable.
public struct RegattaWorktreeReconciler: Sendable {

    private let existenceChecker: any WorktreeExistenceChecking

    /// Creates a reconciler.
    ///
    /// - Parameter existenceChecker: The seam used to test on-disk presence.
    ///   Defaults to ``FileManagerWorktreeExistenceChecker``.
    public init(existenceChecker: any WorktreeExistenceChecking = FileManagerWorktreeExistenceChecker()) {
        self.existenceChecker = existenceChecker
    }

    /// Reconciles a list of persisted worktree snapshots against disk.
    ///
    /// - Parameter snapshots: The persisted assignments to reconcile.
    /// - Returns: A ``WorktreeReconciliation`` partitioning the input into the
    ///   assignments still present on disk and those that are gone.
    public func reconcile(_ snapshots: [WorktreeSnapshot]) -> WorktreeReconciliation {
        var kept: [WorktreeSnapshot] = []
        var dropped: [WorktreeSnapshot] = []
        for snapshot in snapshots {
            if existenceChecker.worktreeExists(at: snapshot.path) {
                kept.append(snapshot)
            } else {
                dropped.append(snapshot)
            }
        }
        return WorktreeReconciliation(kept: kept, dropped: dropped)
    }

    /// Reconciles assignments and rebuilds the live ``RegattaCore/RegattaWorktree``
    /// records for the kept set.
    ///
    /// - Parameter snapshots: The persisted assignments to reconcile.
    /// - Returns: The ``RegattaCore/RegattaWorktree`` values for assignments still
    ///   present on disk, ready to re-register with a worktree manager.
    public func reconciledWorktrees(_ snapshots: [WorktreeSnapshot]) -> [RegattaWorktree] {
        reconcile(snapshots).kept.map { $0.makeWorktree() }
    }
}
