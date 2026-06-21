/// The seam between the orchestrator and an agent's live process surface.
///
/// A `PaneBridge` spawns an agent process from a ``PaneSpec``, exposes its output
/// as an `AsyncStream<PaneOutputEvent>` on the returned ``PaneHandle``, and lets
/// callers terminate or query a process by its ``PaneHandle/ID``.
///
/// ## Why a protocol seam
/// The default production implementation (`ProcessPaneBridge`, issue #14) runs a
/// real `Process` wired to a Ghostty pane. The orchestrator depends only on this
/// protocol, so tests inject a headless fake (driven by `fake-agent.sh`) and the
/// orchestrator never reimplements process management. This is dependency
/// inversion per the cmux architecture rules: the consumer owns the protocol, the
/// service conforms.
///
/// ## Contract
/// - ``spawn(_:)`` starts the process and returns immediately with a handle whose
///   `output` stream yields stdout/stderr chunks and finishes after a single
///   `.terminated(code)` event.
/// - ``terminate(_:)`` stops a running process; it throws
///   ``PaneBridgeError/unknownHandle(_:)`` for an unknown or already-finished ID.
/// - ``isRunning(_:)`` reports whether the process is still alive.
public protocol PaneBridge: Sendable {
    /// Spawns a process described by `spec` and returns a handle to it.
    ///
    /// - Parameter spec: How to launch the process.
    /// - Returns: A ``PaneHandle`` whose `output` stream observes the process.
    /// - Throws: ``PaneBridgeError/spawnFailed(_:)`` if the process can't start.
    func spawn(_ spec: PaneSpec) async throws -> PaneHandle

    /// Terminates the running process addressed by `id`.
    ///
    /// - Parameter id: The handle ID of the process to terminate.
    /// - Throws: ``PaneBridgeError/unknownHandle(_:)`` if no live process is
    ///   tracked for `id`.
    func terminate(_ id: PaneHandle.ID) async throws

    /// Reports whether the process addressed by `id` is still running.
    ///
    /// - Parameter id: The handle ID to query.
    /// - Returns: `true` if the process is alive, `false` otherwise.
    func isRunning(_ id: PaneHandle.ID) async -> Bool
}
