/// Tolerant `Codable` conformance for ``RegattaLoopStatus`` so a loop's
/// lifecycle status survives an app restart (issue #34).
///
/// Encoded as a tagged object. A running loop cannot have its live worker
/// resumed across a restart, but the loop *config and history* are still
/// restored; the engine re-derives a live status when relaunched. Decoding is
/// **tolerant**: an unrecognised `kind` — for example a failure state added by
/// issue #35's error-handling work (a `blocked` status, say) — decodes to
/// ``RegattaLoopStatus/idle`` rather than throwing, so a newer snapshot loads in
/// an older build.
extension RegattaLoopStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
        case summary
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "idle":
            self = .idle
        case "running":
            self = .running
        case "stopped":
            let reason = try container.decode(RegattaLoopStopReason.self, forKey: .reason)
            self = .stopped(reason)
        case "failed":
            let summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
            self = .failed(summary: summary)
        // Tolerant fallback for unknown/added statuses (e.g. #35).
        default:
            self = .idle
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode("idle", forKey: .kind)
        case .running:
            try container.encode("running", forKey: .kind)
        case .stopped(let reason):
            try container.encode("stopped", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .failed(let summary):
            try container.encode("failed", forKey: .kind)
            try container.encode(summary, forKey: .summary)
        }
    }
}
