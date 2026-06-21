/// A handle to a spawned `ci-fix` worker.
///
/// Returned by ``WorkerSpawning/spawn(_:)`` so the reactor can later ask the
/// worker to attempt a fix and learn whether it produced any changes. The real
/// orchestrator (#14/#16) backs this with a pane/agent session; the reactor only
/// depends on this minimal contract.
public protocol CIFixWorkerHandle: Sendable {
    /// Stable identity matching the originating ``CIFixWorkerSpec/id``.
    var id: String { get }

    /// Drives one fix attempt and reports whether the worker produced changes
    /// worth pushing.
    ///
    /// - Returns: `true` when the worker made local commits that should be
    ///   pushed; `false` when it could not produce a fix this iteration.
    func attemptFix() async -> Bool
}

/// The seam for spawning a `ci-fix` worker, mirroring the pane bridge /
/// orchestrator from #14/#16.
///
/// ## Wiring note (#14/#16)
/// Defined locally so the CI watch loop (#30) can ship first. When the
/// orchestrator lands, its worker-spawning surface conforms to this protocol (or
/// this protocol is lifted to the shared seam package) and the composition root
/// injects the real spawner into ``CIFixReactor``. Tests inject a stub.
public protocol WorkerSpawning: Sendable {
    /// Spawns a `ci-fix` worker scoped to the spec's PR branch/worktree.
    ///
    /// - Parameter spec: The worker request describing the PR and branch.
    /// - Returns: A handle to drive and observe the spawned worker.
    func spawn(_ spec: CIFixWorkerSpec) async -> any CIFixWorkerHandle
}
