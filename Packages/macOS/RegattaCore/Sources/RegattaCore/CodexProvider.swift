/// An ``AgentProvider`` for OpenAI's Codex CLI (`codex`).
///
/// Launches `codex exec <prompt>` — Codex's non-interactive subcommand that runs a
/// single prompt to completion and exits (as opposed to the default interactive
/// TUI). The executable is resolved via `/usr/bin/env` so `codex` is found on
/// `PATH`.
///
/// > Note: The exact non-interactive invocation is flagged for Josh's confirmation
/// > (see the PR's "Needs Josh's decision" section). `codex exec "<prompt>"` is
/// > Codex's documented headless one-shot mode as of this writing.
public struct CodexProvider: AgentProvider {
    /// Creates a Codex provider.
    public init() {}

    public var id: AgentProviderID { .codex }

    public func makeLaunch(prompt: String) -> WorkerAgentLaunch {
        WorkerAgentLaunch(
            executableURL: AgentExecutable.envURL,
            arguments: ["codex", "exec"],
            environment: [:],
            appendPrompt: true
        )
    }
}
