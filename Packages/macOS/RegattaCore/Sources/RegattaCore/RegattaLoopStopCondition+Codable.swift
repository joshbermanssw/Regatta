/// Tolerant `Codable` conformance for ``RegattaLoopStopCondition`` so a loop's
/// configured stop condition survives an app restart (issue #34).
///
/// Encoded as a tagged object: `{ "kind": "manual" }` or
/// `{ "kind": "iterations", "count": N }`. Decoding is **tolerant** — an
/// unrecognised `kind` (e.g. a richer condition added later, such as the judged
/// or test-based conditions #20/#21) decodes to ``manual`` rather than throwing,
/// so a newer snapshot still loads in an older build.
extension RegattaLoopStopCondition: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case count
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "iterations":
            let count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
            self = .iterations(count)
        case "manual":
            self = .manual
        // Tolerant fallback for unknown/added conditions.
        default:
            self = .manual
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try container.encode("manual", forKey: .kind)
        case .iterations(let count):
            try container.encode("iterations", forKey: .kind)
            try container.encode(count, forKey: .count)
        }
    }
}
