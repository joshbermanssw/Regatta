internal import Foundation

/// `Codable` conformance for ``RegattaIterationRecord`` so a loop's iteration
/// history survives an app restart (issue #34).
///
/// The record's `summary` and `tokensUsed` mirror the embedded
/// ``RegattaLoopOutcome``; decoding re-derives them through the designated
/// initialiser so the snapshot stays internally consistent even if a future
/// writer omitted the mirrored fields.
extension RegattaIterationRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case index
        case outcome
        case duration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let index = try container.decode(Int.self, forKey: .index)
        let outcome = try container.decode(RegattaLoopOutcome.self, forKey: .outcome)
        let duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        self.init(index: index, outcome: outcome, duration: duration)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(duration, forKey: .duration)
    }
}
