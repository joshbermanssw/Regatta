public import Foundation

/// A live reference to an agent process running in a pane.
///
/// Returned by ``PaneBridge/spawn(_:)``. A handle carries a stable ``id`` (used to address the
/// pane in ``PaneBridge/terminate(_:)`` and ``PaneBridge/isRunning(_:)``) and the observable
/// ``output`` stream. The handle itself is a value; the underlying process is owned by the
/// ``PaneBridge`` that produced it.
///
/// A handle's ``output`` stream may only be iterated once (it is a single-consumer
/// `AsyncStream`). Spawn a pane per consumer if more than one observer is required.
public struct PaneHandle: Sendable {
    /// A unique, opaque identifier for a spawned pane.
    ///
    /// Wraps a `UUID` so callers cannot conflate a pane id with any other identifier in the
    /// system. Construct a fresh value with `PaneHandle.ID()`.
    public struct ID: Hashable, Sendable, CustomStringConvertible {
        /// The underlying unique value.
        public let rawValue: UUID

        /// Creates a fresh, random pane identifier.
        public init() {
            self.rawValue = UUID()
        }

        /// Wraps an existing `UUID` as a pane identifier.
        ///
        /// - Parameter rawValue: The identifier value to wrap.
        public init(rawValue: UUID) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue.uuidString }
    }

    /// The stable identifier of this pane, used to terminate or query it.
    public let id: ID

    /// The observable output stream for this pane.
    ///
    /// Iterate to receive ``PaneOutputEvent`` values in arrival order. The stream finishes after
    /// the single ``PaneOutputEvent/terminated(_:)`` event. Single-consumer only.
    public let output: AsyncStream<PaneOutputEvent>

    /// Creates a handle. Constructed by ``PaneBridge`` implementations, not by callers.
    ///
    /// - Parameters:
    ///   - id: The pane's stable identifier.
    ///   - output: The pane's observable output stream.
    public init(id: ID, output: AsyncStream<PaneOutputEvent>) {
        self.id = id
        self.output = output
    }
}
