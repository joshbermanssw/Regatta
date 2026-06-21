/// Tolerant `Codable` conformance for ``WorkerStatus`` so a Fleet worker's
/// status can be persisted and restored across an app restart (issue #34).
///
/// Encoded as a tagged object: `{ "kind": "running" }`, or
/// `{ "kind": "failed", "reason": "…" }`. The ``WorkerStatus/blocked(_:)`` state
/// added by issue #35 is encoded explicitly (`{ "kind": "blocked", "reason": … }`)
/// and decoded back to ``WorkerStatus/blocked(_:)`` — it is a human-resolution
/// state and must survive a restart verbatim, not be silently dropped or coerced
/// to ``interrupted``.
///
/// Decoding is otherwise **tolerant**: an unrecognised `kind` (for example a
/// status added by some *future* build) decodes to ``WorkerStatus/interrupted``
/// rather than throwing. ``interrupted`` is the correct neutral restore state for
/// "a worker whose live status this build does not understand", because it is
/// non-terminal and relaunchable.
///
/// Note: persistence stores the worker's *last known* status verbatim; mapping a
/// previously-live worker to ``interrupted`` on restore is the responsibility of
/// the restore layer (`RegattaRestorePlanner`), not of decoding.
extension WorkerStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "queued": self = .queued
        case "running": self = .running
        case "done": self = .done
        case "failed":
            let reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
            self = .failed(reason)
        case "blocked":
            let reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
            self = .blocked(reason)
        case "cancelled": self = .cancelled
        case "interrupted": self = .interrupted
        // Tolerant fallback for truly-unknown/future statuses.
        default: self = .interrupted
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued: try container.encode("queued", forKey: .kind)
        case .running: try container.encode("running", forKey: .kind)
        case .done: try container.encode("done", forKey: .kind)
        case .failed(let reason):
            try container.encode("failed", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .blocked(let reason):
            try container.encode("blocked", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .cancelled: try container.encode("cancelled", forKey: .kind)
        case .interrupted: try container.encode("interrupted", forKey: .kind)
        }
    }
}
