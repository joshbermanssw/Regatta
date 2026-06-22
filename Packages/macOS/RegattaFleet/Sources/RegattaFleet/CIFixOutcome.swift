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

    /// The loop was **cancelled** — the current worker was cancelled/killed by
    /// the user (Fleet ✕), a SIGTERM/SIGKILL, or a shepherd-dismiss cascade. The
    /// loop stopped without spawning another iteration. Unlike ``needsAttention``
    /// this does NOT flag the PR for attention: a cancel is a final, deliberate
    /// stop, not a give-up-and-ask-the-human.
    case cancelled

    /// Whether this outcome flags the PR as needing human attention.
    public var needsAttention: Bool {
        if case .needsAttention = self { return true }
        return false
    }
}
