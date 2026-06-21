/// Tolerant `Codable` conformance for ``ShepherdPollPhase`` so a PR shepherd's
/// watcher phase survives an app restart (issue #34).
///
/// Encoded as a tagged object. Decoding is **tolerant**: an unrecognised `kind`
/// — for example a `paused` phase added by issue #35's gh-backoff work — decodes
/// to ``ShepherdPollPhase/starting`` rather than throwing. ``starting`` is the
/// natural restore phase anyway, since a restored shepherd has no fresh poll
/// data until it resumes polling.
extension ShepherdPollPhase: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "starting": self = .starting
        case "watching": self = .watching
        case "failed":
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .failed(message)
        // Tolerant fallback for unknown/added phases (e.g. #35).
        default: self = .starting
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .starting: try container.encode("starting", forKey: .kind)
        case .watching: try container.encode("watching", forKey: .kind)
        case .failed(let message):
            try container.encode("failed", forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}
