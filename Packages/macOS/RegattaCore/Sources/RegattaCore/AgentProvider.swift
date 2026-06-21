/// An adapter that knows how to launch one CLI agent as a Fleet worker.
///
/// This is the provider-swappable seam from issue #36. A provider generalizes the
/// `WorkerAgentLaunch` factory: given a worker's prompt, it produces the
/// ``WorkerAgentLaunch`` describing the executable, base arguments, and
/// environment for its CLI in non-interactive mode. The orchestrator then combines
/// that launch with the provisioned worktree to build the ``PaneSpec`` it hands to
/// the ``PaneBridge`` — so every provider rides the *same* spawn path and the
/// orchestrator never learns about any specific CLI.
///
/// ## Why a protocol seam
/// The orchestrator depends only on the value-typed ``WorkerAgentLaunch`` a
/// provider yields, not on which CLI produced it. Adding a new provider is a new
/// adapter conforming to this protocol plus an ``AgentProviderID`` case; nothing
/// in the orchestrator or ``PaneBridge`` changes. This is dependency inversion per
/// the cmux architecture rules.
///
/// ## Output-watching is provider-agnostic
/// Providers describe only how to *start* a CLI. They deliberately do not parse or
/// shape the CLI's output: the worker's lifecycle and any loop conditions observe
/// the raw `stdout`/`stderr`/exit-code stream (``PaneOutputEvent``), which is
/// identical across providers. See ``OutputMatchCondition`` for the
/// provider-agnostic output-match check.
///
/// ## Example
/// ```swift
/// let provider: any AgentProvider = CodexProvider()
/// let launch = provider.makeLaunch(prompt: "fix the bug")
/// // launch.executableURL == /usr/bin/env, launch.arguments == ["codex", "exec"]
/// ```
public protocol AgentProvider: Sendable {
    /// The stable id of this provider, recorded on the ``Worker`` and shown in UI.
    var id: AgentProviderID { get }

    /// Builds the launch description for running this CLI on `prompt`.
    ///
    /// The returned ``WorkerAgentLaunch`` describes only the executable, base
    /// arguments, and environment. The orchestrator sets the working directory to
    /// the worktree and appends the prompt when
    /// ``WorkerAgentLaunch/appendPrompt`` is `true`.
    ///
    /// - Parameter prompt: The goal/prompt handed to the agent.
    /// - Returns: How to launch the agent process for this prompt.
    func makeLaunch(prompt: String) -> WorkerAgentLaunch
}
