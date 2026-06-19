import Foundation

/// Who authored a brain chat message.
public enum BrainRole: String, Sendable, Equatable, Codable {
    case user
    case assistant
}

/// A single message in the brain's chat transcript.
///
/// Assistant messages are assembled incrementally from streamed text deltas, so
/// `text` grows as a turn is received.
public struct BrainMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let role: BrainRole
    public var text: String

    public init(id: String, role: BrainRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}
