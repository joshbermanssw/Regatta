/// Tolerant `Codable` conformance for ``ShepherdPollPhase`` so a PR shepherd's
/// watcher phase survives an app restart (issue #34).
///
/// Encoded as a tagged object. The ``ShepherdPollPhase/paused(reason:retryAfter:)``
/// phase added by issue #35's gh-backoff work is encoded explicitly
/// (`{ "kind": "paused", "message": …, "retryAfterSeconds": … }`) and decoded back
/// to `.paused` so the persisted seed snapshot round-trips exactly.
///
/// ## `Duration` serialization
///
/// `retryAfter` is a `Duration`, which has no built-in `Codable` conformance and
/// no stable wire format. It is serialized as its **total seconds** in a `Double`
/// (`retryAfterSeconds`), derived from `Duration.components`
/// (`seconds + attoseconds / 1e18`) and rebuilt on decode with `.seconds(Double)`.
/// Seconds were chosen over raw `(seconds, attoseconds)` components because the
/// backoff is a coarse human-facing delay ("retrying in N s"); sub-second
/// precision is irrelevant and seconds keep the JSON readable.
///
/// Decoding is otherwise **tolerant**: an unrecognised `kind` (a phase added by
/// some *future* build) decodes to ``ShepherdPollPhase/starting`` rather than
/// throwing.
///
/// ## Restore note
///
/// A restored shepherd resumes polling against a freshly-built
/// ``ShepherdWatcher`` (which starts in ``ShepherdPollPhase/starting``), so a
/// persisted `.paused` phase is only the *seed* shown until the first fresh poll
/// lands — the resumed watcher does not inherit the old backoff. Preserving the
/// value on round-trip keeps the persisted snapshot faithful without pinning the
/// live watcher to a stale pause.
extension ShepherdPollPhase: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case message
        case retryAfterSeconds
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
        case "paused":
            let reason = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            let seconds = try container.decodeIfPresent(Double.self, forKey: .retryAfterSeconds) ?? 0
            self = .paused(reason: reason, retryAfter: .seconds(seconds))
        // Tolerant fallback for truly-unknown/future phases.
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
        case .paused(let reason, let retryAfter):
            try container.encode("paused", forKey: .kind)
            try container.encode(reason, forKey: .message)
            let components = retryAfter.components
            let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
            try container.encode(seconds, forKey: .retryAfterSeconds)
        }
    }
}
