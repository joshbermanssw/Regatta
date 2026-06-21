/// The identity of a CLI agent provider a worker can be launched with.
///
/// A worker's provider determines which agent CLI is spawned (Claude Code, Codex,
/// or Gemini). The id is the stable, persistable, UI-surfaceable handle for that
/// choice; the matching ``AgentProvider`` adapter (resolved via
/// ``AgentProviderRegistry``) knows how to build the launch command.
///
/// Claude Code is the default (``AgentProviderID/default``).
public enum AgentProviderID: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// Anthropic's Claude Code CLI (`claude`). The default provider.
    case claudeCode = "claude-code"

    /// OpenAI's Codex CLI (`codex`).
    case codex = "codex"

    /// Google's Gemini CLI (`gemini`).
    case gemini = "gemini"

    /// The provider used when a worker does not specify one: Claude Code.
    public static var `default`: AgentProviderID { .claudeCode }

    /// A short human-readable name for the provider, suitable for a picker label.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }
}
