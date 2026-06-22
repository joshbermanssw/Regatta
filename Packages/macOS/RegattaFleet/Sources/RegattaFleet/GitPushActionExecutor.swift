public import Foundation

/// Runs a real `git push` from a worker's worktree, for the worktree's
/// `HEAD` to the pull request's head branch.
///
/// This is the seam ``GitPushActionExecutor`` delegates the actual subprocess to,
/// so the executor's policy (resolve worktree → push) is testable without a real
/// repo. The app layer injects a git-subprocess conformer; tests inject a
/// recording stub.
public protocol WorktreePushing: Sendable {
    /// Pushes the worktree's current `HEAD` to `branch` on its `origin` remote.
    ///
    /// Equivalent to `git -C <worktree> push origin HEAD:<branch>`.
    ///
    /// - Parameters:
    ///   - worktreePath: The worktree whose committed `HEAD` is pushed.
    ///   - branch: The remote branch to push to (the PR's head branch).
    /// - Throws: A subprocess/git error if the push fails.
    func push(worktreePath: URL, branch: String) async throws
}

/// The error a ``GitPushActionExecutor`` throws when it cannot perform a push.
public enum GitPushActionError: Error, Sendable, Equatable {
    /// The action was not a `push`, so this executor cannot handle it.
    case notAPushAction
    /// No worktree could be resolved for the action's pull request, so there is
    /// nothing to push (e.g. the worker's worktree was never provisioned).
    case noWorktree
    /// The push action carried no target branch in its payload.
    case missingBranch
}

/// The production ``ActionExecuting`` for ``ActionKind/push`` actions: it resolves
/// the worker's worktree for the action's PR and runs a real `git push` of that
/// worktree's commits to the PR's head branch.
///
/// This is the execution half of the **autonomy gate** boundary (issue #32). The
/// ci-fix / review workers are prompted to *commit locally, not push*; the
/// ``AutonomyGate`` then routes the push here — immediately in ``AutonomyMode/auto``
/// or after the user approves in ``AutonomyMode/staged``. Routing the push through
/// this executor (instead of letting the agent `git push` directly) is what keeps
/// the staged-approval gate meaningful.
///
/// Non-push actions (reply/resolve) are delegated to an injected fallback executor
/// so a single executor can be installed on the gate while #31's reply/resolve
/// executor handles the rest. The default fallback is ``NoopActionExecutor``.
public struct GitPushActionExecutor: ActionExecuting {
    /// Resolves the worktree to push for a given pending push action, or `nil` if
    /// none is known. Injected by the composition root (backed by the
    /// orchestrator's per-worker worktree map); tests inject a fixture path.
    private let resolveWorktree: @Sendable (PendingAction) async -> URL?

    /// The git-push subprocess seam.
    private let pusher: any WorktreePushing

    /// The executor handling non-push actions (reply/resolve).
    private let fallback: any ActionExecuting

    /// Creates a push executor.
    ///
    /// - Parameters:
    ///   - resolveWorktree: Maps a push action to the worktree whose commits to
    ///     push. Returning `nil` makes the push fail with
    ///     ``GitPushActionError/noWorktree``.
    ///   - pusher: The git-push subprocess seam.
    ///   - fallback: Handles non-push actions. Defaults to ``NoopActionExecutor``.
    public init(
        resolveWorktree: @escaping @Sendable (PendingAction) async -> URL?,
        pusher: any WorktreePushing,
        fallback: any ActionExecuting = NoopActionExecutor()
    ) {
        self.resolveWorktree = resolveWorktree
        self.pusher = pusher
        self.fallback = fallback
    }

    public func execute(_ action: PendingAction) async throws {
        guard action.kind == .push else {
            try await fallback.execute(action)
            return
        }
        guard let branch = action.payload?["branch"], !branch.isEmpty else {
            throw GitPushActionError.missingBranch
        }
        guard let worktree = await resolveWorktree(action) else {
            throw GitPushActionError.noWorktree
        }
        try await pusher.push(worktreePath: worktree, branch: branch)
    }
}
