public import Foundation

/// A handle to a process launched by a ``PaneBridge``.
///
/// Carries a stable ``ID`` (used to terminate or query the process) and the
/// `AsyncStream` of ``PaneOutputEvent`` values the process produces. The stream
/// finishes after a `.terminated` event is emitted.
///
/// The handle is a value type; the live process is owned by the ``PaneBridge``
/// actor that created it. Use ``ID`` to address the process for `terminate` /
/// `isRunning`.
public struct PaneHandle: Sendable, Identifiable {
    /// A stable, type-safe identifier for a launched pane process.
    public struct ID: Hashable, Sendable, CustomStringConvertible {
        /// The backing UUID.
        public let rawValue: UUID

        /// Creates an identifier wrapping the given UUID (a fresh one by default).
        ///
        /// - Parameter rawValue: The backing UUID. Defaults to a fresh `UUID()`.
        public init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue.uuidString }
    }

    /// The stable identifier addressing this process at the bridge.
    public let id: ID

    /// The stream of output events the process produces, terminated by a
    /// `.terminated` event after which the stream finishes.
    public let output: AsyncStream<PaneOutputEvent>

    /// Creates a `PaneHandle`.
    ///
    /// - Parameters:
    ///   - id: The stable identifier addressing the process. Defaults to a fresh ID.
    ///   - output: The stream of output events the process produces.
    public init(id: ID = ID(), output: AsyncStream<PaneOutputEvent>) {
        self.id = id
        self.output = output
    }
}
