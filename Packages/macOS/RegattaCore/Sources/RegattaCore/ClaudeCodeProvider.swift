/// The default ``AgentProvider``: Anthropic's Claude Code CLI (`claude`).
///
/// Launches `claude -p <prompt>` — the CLI's non-interactive "print" mode, which
/// runs the prompt to completion and exits, which is what a headless worker needs.
///
/// The launch here targets `/usr/bin/env` with `"claude"` as the leading argument
/// as a portable default. The app-layer spawner rewrites this to the **resolved
/// absolute executable** with a complete environment (dropping the leading
/// `"claude"` token), so a spawned worker does not depend on the GUI app's minimal
/// `PATH` to find `claude` — the cause of the worker "exited with code 127" bug.
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
            // `--strict-mcp-config` + `--settings {"disableAllHooks":true}` isolate the
            // worker from the user's global ~/.claude hooks and MCP servers, so a
            // spawned ci-fix / review / Fleet worker starts fast and clean (the same
            // isolation the Brain uses). OAuth/keychain auth is unaffected.
            arguments: ["claude", "-p", "--strict-mcp-config", "--settings", "{\"disableAllHooks\":true}"],
            environment: [:],
            appendPrompt: true
        )
    }
}
