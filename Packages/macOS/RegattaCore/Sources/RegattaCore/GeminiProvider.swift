/// An ``AgentProvider`` for Google's Gemini CLI (`gemini`).
///
/// Launches `gemini -p <prompt>` — the Gemini CLI's non-interactive prompt flag,
/// which runs the prompt to completion and prints the result rather than opening
/// the interactive session. The executable is resolved via `/usr/bin/env` so
/// `gemini` is found on `PATH`.
///
/// > Note: The exact non-interactive flag is flagged for Josh's confirmation (see
/// > the PR's "Needs Josh's decision" section). `gemini -p "<prompt>"` is the
/// > Gemini CLI's documented headless prompt mode as of this writing.
public struct GeminiProvider: AgentProvider {
    /// Creates a Gemini provider.
    public init() {}

    public var id: AgentProviderID { .gemini }

    public func makeLaunch(prompt: String) -> WorkerAgentLaunch {
        WorkerAgentLaunch(
            executableURL: AgentExecutable.envURL,
            // `--yolo` puts the headless Gemini worker in auto-approve mode so it can
            // edit files and run git/tests without an interactive approval prompt
            // (which cannot be answered headlessly). The worker runs in an isolated,
            // throwaway git worktree, so auto-approve is scoped to that tree — the
            // autonomous-agent equivalent of Claude Code's
            // `--dangerously-skip-permissions`.
            arguments: ["gemini", "--yolo", "-p"],
            environment: [:],
            appendPrompt: true
        )
    }
}
