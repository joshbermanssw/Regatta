/// The per-PR autonomy policy that gates every outward-facing shepherd action
/// (push, reply, resolve).
///
/// This is the **safety switch** for issue #32: it decides whether the shepherd
/// may act on a real pull request on the user's behalf, or whether each action
/// is held for one-click approval first.
///
/// ## Default
/// New handoffs default to ``staged`` — the conservative choice. The shepherd
/// never pushes, replies, or resolves without explicit approval until the user
/// flips the PR to ``auto``. This default is a deliberate human-in-the-loop
/// safety policy (issue is `type:hitl`); see the "Needs Josh's decision" PR
/// section.
public enum AutonomyMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Hold every outward action as a pending approval. The user approves or
    /// rejects each one before it executes. **Default for new handoffs.**
    case staged

    /// Execute every outward action immediately, without approval.
    case auto
}
