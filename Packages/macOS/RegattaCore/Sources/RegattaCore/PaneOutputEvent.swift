/// A single observable event emitted by a ``PaneBridge`` handle's output stream.
///
/// The orchestrator and downstream condition checks (issue #18/#19) iterate the
/// handle's `AsyncStream<PaneOutputEvent>` to observe an agent's lifecycle: its
/// stdout/stderr text and the terminal exit code.
public enum PaneOutputEvent: Sendable, Equatable {
    /// A chunk of standard-output text.
    case stdout(String)

    /// A chunk of standard-error text.
    case stderr(String)

    /// The process exited with the given status code. This is the final event
    /// on the stream; the stream finishes immediately after it.
    case terminated(Int32)
}
