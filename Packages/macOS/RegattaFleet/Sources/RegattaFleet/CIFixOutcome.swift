/// The terminal result of a CI fix loop for one pull request.
///
/// The loop runs until the PR's checks are green or a cap is hit. The shepherd
/// records this outcome so the Fleet UI can show success or surface a PR that
/// needs human attention.
public enum CIFixOutcome: Sendable, Equatable {
    /// The PR's checks turned green; the loop stopped on success.
    case greenSuccess

    /// The loop hit its iteration cap without reaching green, or could not make
    /// progress (no fix produced, or a push was denied by the autonomy gate).
    /// The PR is flagged for human attention with a user-facing reason.
    case needsAttention(reason: String)

    /// Whether this outcome flags the PR as needing human attention.
    public var needsAttention: Bool {
        if case .needsAttention = self { return true }
        return false
    }
}
