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
///
/// The ``ShepherdState/needsAttention`` human-resolution flag added by issue #35
/// is persisted and restored: it marks a PR the shepherd gave up automating, so
/// the "needs attention" banner and its reason must reappear after a restart. It
/// decodes with `decodeIfPresent` so snapshots written before #35 (no key) still
/// load, defaulting to `nil`.
extension ShepherdState: Codable {
    private enum CodingKeys: String, CodingKey {
        case pullRequest
        case phase
        case checks
        case reviewThreads
        case conversationComments
        case reviews
        case autonomyMode
        case needsAttention
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pullRequest = try container.decode(PullRequestRef.self, forKey: .pullRequest)
        let phase = try container.decode(ShepherdPollPhase.self, forKey: .phase)
        let checks = try container.decodeIfPresent(PRCheckSummary.self, forKey: .checks)
            ?? PRCheckSummary(checks: [])
        let reviewThreads = try container.decodeIfPresent([ReviewThread].self, forKey: .reviewThreads)
            ?? []
        let conversationComments = try container.decodeIfPresent(
            [PRConversationComment].self, forKey: .conversationComments
        ) ?? []
        let reviews = try container.decodeIfPresent([PRReview].self, forKey: .reviews) ?? []
        let autonomyMode = try container.decodeIfPresent(AutonomyMode.self, forKey: .autonomyMode)
            ?? .staged
        let needsAttention = try container.decodeIfPresent(String.self, forKey: .needsAttention)
        self.init(
            pullRequest: pullRequest,
            phase: phase,
            checks: checks,
            reviewThreads: reviewThreads,
            conversationComments: conversationComments,
            reviews: reviews,
            autonomyMode: autonomyMode,
            needsAttention: needsAttention
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pullRequest, forKey: .pullRequest)
        try container.encode(phase, forKey: .phase)
        try container.encode(checks, forKey: .checks)
        try container.encode(reviewThreads, forKey: .reviewThreads)
        try container.encode(conversationComments, forKey: .conversationComments)
        try container.encode(reviews, forKey: .reviews)
        try container.encode(autonomyMode, forKey: .autonomyMode)
        try container.encodeIfPresent(needsAttention, forKey: .needsAttention)
    }
}
