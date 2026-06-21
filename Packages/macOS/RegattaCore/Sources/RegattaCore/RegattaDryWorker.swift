public import Foundation

/// A ``RegattaLoopWorker`` decorator implementing issue #21's `dry` stop
/// condition: stop the loop once an iteration produces **no new changes**.
///
/// It wraps an inner worker and, after each successful inner iteration, probes
/// the worker's worktree for uncommitted changes via a ``RegattaDiffProbing``
/// seam. If the iteration left the worktree clean (no diff), the outcome is
/// re-stamped as ``RegattaLoopOutcome/Kind/succeeded`` so the paired
/// ``RegattaDryLoopCondition`` stops the loop with
/// ``RegattaLoopStopReason/goalReached``; otherwise the inner outcome (typically
/// ``RegattaLoopOutcome/Kind/progressed``) flows through unchanged. The dry
/// result and its detail are appended to a ``RegattaLoopJournal`` so the "why we
/// stopped" note lands in the loop's history.
///
/// The engine still enforces all safety caps on top — this decorator never
/// bypasses them; it only ever converts a `progressed` outcome into a normal
/// `succeeded` stop.
///
/// ## Usage
/// ```swift
/// let dry = RegattaDryWorker(
///     wrapping: agentWorker,
///     worktreePath: worktree.path,
///     diffProbe: RegattaGitDiffProbe(),
///     journal: journal
/// )
/// let engine = RegattaLoopEngine(
///     configuration: config,
///     worker: dry,
///     condition: RegattaDryLoopCondition()
/// )
/// ```
public struct RegattaDryWorker: RegattaLoopWorker {
    private let inner: any RegattaLoopWorker
    private let worktreePath: URL
    private let diffProbe: any RegattaDiffProbing
    private let journal: RegattaLoopJournal

    /// Creates a dry worker.
    ///
    /// - Parameters:
    ///   - inner: The underlying per-iteration worker (e.g. the agent worker).
    ///   - worktreePath: The worktree to probe for new changes after each
    ///     iteration (from ``RegattaWorktreeManager``).
    ///   - diffProbe: The change-detection seam. Defaults to
    ///     ``RegattaGitDiffProbe``.
    ///   - journal: The journal to record dry results into.
    public init(
        wrapping inner: any RegattaLoopWorker,
        worktreePath: URL,
        diffProbe: any RegattaDiffProbing = RegattaGitDiffProbe(),
        journal: RegattaLoopJournal
    ) {
        self.inner = inner
        self.worktreePath = worktreePath
        self.diffProbe = diffProbe
        self.journal = journal
    }

    /// Runs the inner iteration, then converts a no-diff result into a normal
    /// `succeeded` stop.
    ///
    /// A failed inner outcome is passed straight through (the diff is irrelevant
    /// once the iteration failed). Otherwise the worktree is probed; a clean
    /// worktree re-stamps the outcome as `succeeded` with a "no new changes"
    /// summary, and a dirty worktree leaves the inner outcome intact.
    public func runIteration(index: Int, goal: String) async throws -> RegattaLoopOutcome {
        let outcome = try await inner.runIteration(index: index, goal: goal)

        guard outcome.kind != .failed else {
            return outcome
        }

        let hasChanges = try await diffProbe.hasUncommittedChanges(at: worktreePath)
        let detail = hasChanges
            ? "iteration \(index) produced new changes"
            : "iteration \(index) produced no new changes (dry)"
        await journal.record(
            RegattaLoopJournal.DryRecord(
                iterationIndex: index,
                hadNewChanges: hasChanges,
                detail: detail
            )
        )

        guard !hasChanges else {
            return outcome
        }

        return RegattaLoopOutcome(
            kind: .succeeded,
            summary: "\(outcome.summary) — no new changes (dry); stopping",
            tokensUsed: outcome.tokensUsed
        )
    }
}
