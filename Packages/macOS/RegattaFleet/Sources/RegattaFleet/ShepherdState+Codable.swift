internal import RegattaGitHub

/// `Codable` conformance for ``ShepherdState`` so a PR shepherd's last-known
/// snapshot survives an app restart (issue #34, state persistence + session
/// restore).
///
/// Only the stored properties are encoded; the `id`, `kind`, `title`, and
/// `unresolvedThreadCount` are computed and re-derived on decode. Every stored
/// property is `Codable` (with `phase` and the GitHub types using their own
/// conformances), so the synthesised conformance over the stored set is correct.
///
/// On restore the shepherd resumes polling automatically (PR shepherds are
/// event-driven, not process-backed), so this persisted snapshot is only the
/// *seed* shown until the first fresh poll completes.
extension ShepherdState: Codable {
    private enum CodingKeys: String, CodingKey {
        case pullRequest
        case phase
        case checks
        case reviewThreads
        case autonomyMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pullRequest = try container.decode(PullRequestRef.self, forKey: .pullRequest)
        let phase = try container.decode(ShepherdPollPhase.self, forKey: .phase)
        let checks = try container.decodeIfPresent(PRCheckSummary.self, forKey: .checks)
            ?? PRCheckSummary(checks: [])
        let reviewThreads = try container.decodeIfPresent([ReviewThread].self, forKey: .reviewThreads)
            ?? []
        let autonomyMode = try container.decodeIfPresent(AutonomyMode.self, forKey: .autonomyMode)
            ?? .staged
        self.init(
            pullRequest: pullRequest,
            phase: phase,
            checks: checks,
            reviewThreads: reviewThreads,
            autonomyMode: autonomyMode
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pullRequest, forKey: .pullRequest)
        try container.encode(phase, forKey: .phase)
        try container.encode(checks, forKey: .checks)
        try container.encode(reviewThreads, forKey: .reviewThreads)
        try container.encode(autonomyMode, forKey: .autonomyMode)
    }
}
