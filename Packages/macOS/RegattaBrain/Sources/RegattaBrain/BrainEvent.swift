import Foundation

/// High-level state of the brain session, surfaced to the UI for the status dot.
public enum BrainStatus: Sendable, Equatable {
    /// Connected and waiting for input.
    case idle
    /// A turn is in flight (the agent is responding).
    case thinking
    /// The underlying process exited with the given status code.
    case exited(Int32)
    /// The session failed to start or errored fatally.
    case failed(String)
}

/// An event emitted by a running ``BrainSession`` over its `AsyncStream`.
public enum BrainEvent: Sendable, Equatable {
    /// A chunk of assistant text arrived (streamed).
    case assistantDelta(String)
    /// The current assistant turn is complete.
    case turnCompleted
    /// The session status changed.
    case status(BrainStatus)
    /// The underlying process exited; the stream finishes after this.
    case exited(code: Int32)
}
