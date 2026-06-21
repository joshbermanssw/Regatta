public import Foundation

/// The integration seam between Regatta worker management and the host's pane/terminal layer.
///
/// A `PaneBridge` is the single, minimal boundary through which Regatta spawns a CLI coding-agent
/// process in a pane, terminates it, and observes its output. Everything above this protocol —
/// the Orchestrator (issue #16), loop engine, and condition checks — depends only on
/// `any PaneBridge`, never on a concrete pane implementation. This keeps the surface that touches
/// upstream cmux tiny and replaceable.
///
/// ## Implementations
/// - ``ProcessPaneBridge`` is the default, host-independent implementation. It runs the agent as
///   a plain subprocess (`Process`) and is the implementation the test harness and headless CI
///   use. It is sufficient for spawn/terminate/observe today.
/// - A future cmux-backed implementation conforms to this same protocol and routes `spawn` to a
///   visible Ghostty pane (see the integration-seam notes in `PaneBridge.md`). Because the
///   protocol is the only contract, swapping implementations is a one-line composition change in
///   the app target and requires no changes upstream of this seam.
///
/// ## Concurrency
/// Conformers are `Sendable` actors (or otherwise thread-safe). All methods are `async`.
/// Observation is delivered as an `AsyncStream` on the returned ``PaneHandle``, never via
/// callbacks or `NotificationCenter`.
///
/// ## Usage
/// ```swift
/// let bridge: any PaneBridge = ProcessPaneBridge()
/// let handle = try await bridge.spawn(spec)
/// for await event in handle.output {
///     switch event {
///     case .stdout(let text): /* check for a completion marker */ break
///     case .stderr(let text): break
///     case .terminated(let code): /* loop decides retry/stop */ break
///     }
/// }
/// try? await bridge.terminate(handle.id)
/// ```
public protocol PaneBridge: Sendable {
    /// Spawns an agent process described by `spec` in a pane and begins streaming its output.
    ///
    /// The returned handle's ``PaneHandle/output`` stream starts delivering events immediately;
    /// callers should begin iterating it promptly so no output is buffered unboundedly.
    ///
    /// - Parameter spec: The process to run, including its working directory.
    /// - Returns: A ``PaneHandle`` addressing the running pane.
    /// - Throws: ``PaneBridgeError/spawnFailed(_:)`` if the process cannot be launched.
    func spawn(_ spec: PaneSpec) async throws -> PaneHandle

    /// Terminates the process and its pane for the given handle id.
    ///
    /// Termination is clean: the process is signalled, the output stream receives a final
    /// ``PaneOutputEvent/terminated(_:)`` event, and the handle is no longer tracked. Calling
    /// this for a handle that has already finished or was never spawned throws
    /// ``PaneBridgeError/unknownHandle(_:)``.
    ///
    /// - Parameter id: The handle id returned by ``spawn(_:)``.
    /// - Throws: ``PaneBridgeError/unknownHandle(_:)`` if no active pane matches `id`.
    func terminate(_ id: PaneHandle.ID) async throws

    /// Reports whether a pane for the given handle id is still running.
    ///
    /// Returns `false` for an id that has exited (whether naturally or via ``terminate(_:)``) or
    /// was never spawned. Useful for downstream condition checks that poll lifecycle state.
    ///
    /// - Parameter id: The handle id to query.
    /// - Returns: `true` if the pane's process is still alive.
    func isRunning(_ id: PaneHandle.ID) async -> Bool
}
