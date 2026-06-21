/// A ``PaneBridge`` placeholder used until the real Pane Bridge (issue #14) lands.
///
/// Every ``spawn(_:)`` fails with ``PaneBridgeError/spawnFailed(_:)`` carrying a
/// clear "depends on #14" message, so a worker the brain requests surfaces as
/// ``WorkerStatus/failed(_:)`` in the Fleet rather than silently doing nothing.
/// The orchestrator and Fleet UI are fully wired against the ``PaneBridge`` seam;
/// the only remaining step once #14 merges is to construct the orchestrator with
/// `ProcessPaneBridge()` in place of this type.
///
/// This is intentionally not a process implementation — reimplementing the Pane
/// Bridge here is out of scope for the orchestrator (issue #16).
public struct UnavailablePaneBridge: PaneBridge {

    /// Creates the placeholder bridge.
    public init() {}

    public func spawn(_ spec: PaneSpec) async throws -> PaneHandle {
        throw PaneBridgeError.spawnFailed(
            "Pane Bridge is not available yet (depends on issue #14)."
        )
    }

    public func terminate(_ id: PaneHandle.ID) async throws {
        throw PaneBridgeError.unknownHandle(id)
    }

    public func isRunning(_ id: PaneHandle.ID) async -> Bool {
        false
    }
}
