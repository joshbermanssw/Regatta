import Foundation

/// The dependency-inversion seam for the loop view's "jump into terminal"
/// (human-takeover) control action.
///
/// The loop view never knows how a worker's terminal pane is surfaced — that is
/// the worker-orchestration / pane work of issues #16 and #17. The view depends
/// only on this protocol; the app's composition root injects a concrete
/// conformer once the pane plumbing lands. Until then a no-op stub keeps the
/// rest of the loop view (define / edit / history / pause / stop) fully
/// functional.
///
/// ## Usage
/// ```swift
/// let viewModel = RegattaLoopViewModel(
///     engineFactory: factory,
///     terminalJumper: MyWorkerPaneJumper(workspace: workspace)
/// )
/// ```
@MainActor
public protocol RegattaLoopTerminalJumping: AnyObject {
    /// Whether jumping into the worker's terminal is currently possible.
    ///
    /// The loop view disables its "jump into terminal" control when this is
    /// `false` (for example while the worker pane is not yet wired up behind the
    /// #16/#17 seam).
    var canJumpIntoTerminal: Bool { get }

    /// Focuses the worker's terminal pane so a human can take over.
    ///
    /// - Parameter workerID: The identifier of the worker whose pane to focus.
    func jumpIntoTerminal(workerID: String)
}

/// A no-op ``RegattaLoopTerminalJumping`` used until the #16/#17 worker-pane
/// plumbing is merged.
///
/// Reports ``canJumpIntoTerminal`` as `false` so the loop view shows the control
/// in a disabled state instead of pretending it works.
public final class RegattaLoopTerminalJumpUnavailable: RegattaLoopTerminalJumping {
    /// Creates the unavailable stub.
    public init() {}

    /// Always `false`: no pane is reachable yet.
    public var canJumpIntoTerminal: Bool { false }

    /// No-op. Records nothing and focuses nothing.
    public func jumpIntoTerminal(workerID: String) {}
}
