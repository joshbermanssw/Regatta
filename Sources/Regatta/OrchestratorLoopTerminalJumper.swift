import Foundation
import RegattaLoopUI

/// The production ``RegattaLoopTerminalJumping`` conformer for the live loop view
/// (Seam B human-takeover).
///
/// "Jump into terminal" focuses the worker's terminal pane so a human can take
/// over. Today's orchestrator runs each agent through ``ProcessPaneBridge``, which
/// launches the agent **headless** (a plain subprocess with no visible Ghostty
/// surface), so there is no pane to focus. Rather than fake the action, this
/// conformer reports ``canJumpIntoTerminal`` as `false` so the loop view shows the
/// control disabled with an explanatory tooltip.
///
/// A fully interactive in-pane takeover needs a Ghostty-backed `PaneBridge` (the
/// deferred #14 HITL decision): once a worker's agent runs in a visible Ghostty
/// pane, this type gains a real pane handle and flips ``canJumpIntoTerminal`` to
/// `true`, focusing that pane. The protocol seam stays unchanged.
@MainActor
final class OrchestratorLoopTerminalJumper: RegattaLoopTerminalJumping {

    /// Creates the jumper.
    init() {}

    /// `false`: ``ProcessPaneBridge`` agents are headless, so no terminal pane is
    /// reachable to focus. Flips to `true` once a Ghostty-backed `PaneBridge`
    /// (#14) gives workers a visible pane.
    var canJumpIntoTerminal: Bool { false }

    /// No-op while no visible pane exists for the worker. With a Ghostty-backed
    /// `PaneBridge` this focuses the worker's pane.
    func jumpIntoTerminal(workerID: String) {}
}
