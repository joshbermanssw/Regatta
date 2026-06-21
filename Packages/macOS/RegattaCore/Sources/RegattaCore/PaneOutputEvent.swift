public import Foundation

/// A single observable event from an agent pane's output stream.
///
/// Yielded in arrival order by ``PaneHandle/output``. Downstream condition checks (e.g. the
/// Orchestrator, issue #16) iterate this stream to decide when an agent has produced a marker,
/// errored, or finished. The stream finishes after exactly one ``terminated(_:)`` event.
public enum PaneOutputEvent: Sendable, Equatable {
    /// A chunk of text written to the agent's standard output.
    ///
    /// Chunks are delivered as they are read; a single logical line may span chunks and a
    /// single chunk may contain multiple lines. Consumers that need line semantics should
    /// buffer and split themselves.
    case stdout(String)

    /// A chunk of text written to the agent's standard error.
    case stderr(String)

    /// The process exited with the given status code.
    ///
    /// This is always the final event on the stream; no further events follow it. A value of
    /// `0` indicates a clean exit; any other value is the process's exit/termination code.
    case terminated(Int32)
}
