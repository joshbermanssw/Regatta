/// The default ``AgentProvider``: Anthropic's Claude Code CLI (`claude`).
///
/// Launches `claude -p <prompt>` — the CLI's non-interactive "print" mode, which
/// runs the prompt to completion and exits, which is what a headless worker needs.
/// The executable is resolved via `/usr/bin/env` so `claude` is found on `PATH`.
///
/// > Note: The exact non-interactive flag is flagged for Josh's confirmation (see
/// > the PR's "Needs Josh's decision" section). `claude -p` is Claude Code's
/// > documented headless print mode as of this writing.
public struct ClaudeCodeProvider: AgentProvider {
    /// Creates a Claude Code provider.
    public init() {}

    public var id: AgentProviderID { .claudeCode }

    public func makeLaunch(prompt: String) -> WorkerAgentLaunch {
        WorkerAgentLaunch(
            executableURL: AgentExecutable.envURL,
            arguments: ["claude", "-p"],
            environment: [:],
            appendPrompt: true
        )
    }
}
