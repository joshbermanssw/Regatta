public import Foundation

/// A request from the brain to spawn a Fleet worker.
///
/// This is the brain→orchestrator spawn interface: a goal/prompt for the agent,
/// the target repository to work in, and how to launch the agent process inside
/// the provisioned worktree.
///
/// The worker's CLI agent is chosen by ``AgentProvider`` (issue #36). The
/// recommended initializer takes a provider and records its ``providerID`` while
/// deriving the ``agentLaunch`` from it, so the provider choice rides the same
/// orchestrator → ``PaneBridge`` spawn path. Claude Code is the default.
///
/// ## Example
/// ```swift
/// // Default provider (Claude Code):
/// let spec = WorkerSpec(
///     name: "Fix login bug",
///     prompt: "Investigate and fix the 500 on /login",
///     repoURL: URL(fileURLWithPath: "/path/to/repo")
/// )
///
/// // Explicit provider:
/// let codexSpec = WorkerSpec(
///     name: "Codex worker",
///     prompt: "Add a test",
///     repoURL: URL(fileURLWithPath: "/path/to/repo"),
///     provider: CodexProvider()
/// )
/// let id = await orchestrator.spawnWorker(spec)
/// ```
public struct WorkerSpec: Sendable, Equatable {
    /// A short human-readable name shown in the Fleet list.
    public let name: String

    /// The goal/prompt handed to the agent.
    public let prompt: String

    /// The git repository the worker operates on; a fresh worktree is branched
    /// from it for isolation.
    public let repoURL: URL

    /// The CLI agent provider this worker is launched with. Recorded on the
    /// ``Worker`` snapshot and shown in the Fleet UI.
    public let providerID: AgentProviderID

    /// How to launch the agent process inside the worktree.
    ///
    /// The orchestrator appends the prompt to the agent's arguments and sets the
    /// process working directory to the provisioned worktree, so the launch here
    /// describes only the executable, base arguments, and environment. Derived
    /// from the chosen provider.
    public let agentLaunch: WorkerAgentLaunch

    /// Creates a `WorkerSpec` for a chosen provider (Claude Code by default).
    ///
    /// The provider builds the ``agentLaunch`` for `prompt` and its
    /// ``AgentProvider/id`` is recorded as ``providerID``.
    ///
    /// - Parameters:
    ///   - name: A short human-readable name shown in the Fleet list.
    ///   - prompt: The goal/prompt handed to the agent.
    ///   - repoURL: The git repository the worker operates on.
    ///   - provider: The CLI agent provider to launch. Defaults to
    ///     ``ClaudeCodeProvider``.
    public init(
        name: String,
        prompt: String,
        repoURL: URL,
        provider: any AgentProvider = ClaudeCodeProvider()
    ) {
        self.name = name
        self.prompt = prompt
        self.repoURL = repoURL
        self.providerID = provider.id
        self.agentLaunch = provider.makeLaunch(prompt: prompt)
    }

    /// Creates a `WorkerSpec` from an explicit launch description.
    ///
    /// Use the provider initializer instead unless you need to supply a custom
    /// launch directly (e.g. a fake agent in tests). The provider id is recorded
    /// for UI/bookkeeping and defaults to ``AgentProviderID/default``.
    ///
    /// - Parameters:
    ///   - name: A short human-readable name shown in the Fleet list.
    ///   - prompt: The goal/prompt handed to the agent.
    ///   - repoURL: The git repository the worker operates on.
    ///   - agentLaunch: How to launch the agent process inside the worktree.
    ///   - providerID: The provider id to record. Defaults to
    ///     ``AgentProviderID/default``.
    public init(
        name: String,
        prompt: String,
        repoURL: URL,
        agentLaunch: WorkerAgentLaunch,
        providerID: AgentProviderID = .default
    ) {
        self.name = name
        self.prompt = prompt
        self.repoURL = repoURL
        self.providerID = providerID
        self.agentLaunch = agentLaunch
    }
}

/// How to launch a worker's agent process, independent of the worktree it runs in.
///
/// The orchestrator combines this with the provisioned worktree path to build the
/// final ``PaneSpec`` handed to the ``PaneBridge``.
public struct WorkerAgentLaunch: Sendable, Equatable {
    /// The agent executable to run (e.g. `/usr/bin/env` to find `claude` on PATH).
    public let executableURL: URL

    /// Base arguments passed before the prompt. The orchestrator appends the
    /// worker's prompt as a trailing argument when `appendPrompt` is `true`.
    public let arguments: [String]

    /// The environment the agent runs with.
    public let environment: [String: String]

    /// Whether the orchestrator appends ``WorkerSpec/prompt`` as a final argument.
    /// Set `false` when the agent reads its prompt from stdin or a file instead.
    public let appendPrompt: Bool

    /// Creates a `WorkerAgentLaunch`.
    ///
    /// - Parameters:
    ///   - executableURL: The agent executable to run.
    ///   - arguments: Base arguments passed before the prompt. Defaults to empty.
    ///   - environment: The environment the agent runs with. Defaults to empty.
    ///   - appendPrompt: Whether to append the prompt as a trailing argument.
    ///     Defaults to `true`.
    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        appendPrompt: Bool = true
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.appendPrompt = appendPrompt
    }
}
