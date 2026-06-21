/// Resolves an ``AgentProviderID`` to its concrete ``AgentProvider`` adapter.
///
/// This is the single lookup table that maps the persistable/UI-surfaceable
/// provider id back to the adapter that builds its launch command. The Fleet UI
/// records an ``AgentProviderID`` on a worker; the registry turns that id back into
/// the adapter when a ``WorkerSpec`` is built. Keeping the mapping in one place
/// (driven by the ``AgentProviderID/allCases`` exhaustive switch) means adding a
/// provider is one new enum case plus one new adapter.
///
/// ## Example
/// ```swift
/// let provider = AgentProviderRegistry.provider(for: .gemini)
/// let launch = provider.makeLaunch(prompt: "fix the bug")
/// ```
public enum AgentProviderRegistry {
    /// Returns the adapter for `id`.
    ///
    /// - Parameter id: The provider id to resolve.
    /// - Returns: The matching ``AgentProvider`` adapter.
    public static func provider(for id: AgentProviderID) -> any AgentProvider {
        switch id {
        case .claudeCode: return ClaudeCodeProvider()
        case .codex: return CodexProvider()
        case .gemini: return GeminiProvider()
        }
    }
}
