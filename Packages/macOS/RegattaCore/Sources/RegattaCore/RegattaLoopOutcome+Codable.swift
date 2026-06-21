/// `Codable` conformance for ``RegattaLoopOutcome`` so a loop's per-iteration
/// outcomes survive an app restart (issue #34).
///
/// ``RegattaLoopOutcome/Kind`` is already a `String`-backed `Codable` enum, but
/// the synthesised raw-value decode throws on an unknown raw value. This
/// conformance decodes the kind **tolerantly**: an unrecognised kind decodes to
/// ``RegattaLoopOutcome/Kind/progressed`` (the neutral "kept going" outcome)
/// rather than throwing, so a snapshot written by a newer build still loads.
extension RegattaLoopOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case summary
        case tokensUsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .kind)
        let kind = Kind(rawValue: rawKind) ?? .progressed
        let summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        let tokensUsed = try container.decodeIfPresent(Int.self, forKey: .tokensUsed) ?? 0
        self.init(kind: kind, summary: summary, tokensUsed: tokensUsed)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(summary, forKey: .summary)
        try container.encode(tokensUsed, forKey: .tokensUsed)
    }
}
