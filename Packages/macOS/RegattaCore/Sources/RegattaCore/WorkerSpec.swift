public import Foundation

/// A request from the brain to spawn a Fleet worker.
///
/// This is the brain→orchestrator spawn interface: a goal/prompt for the agent,
/// the target repository to work in, and how to launch the agent process inside
/// the provisioned worktree.
///
/// ## Example
/// ```swift
/// let spec = WorkerSpec(
///     name: "Fix login bug",
///     prompt: "Investigate and fix the 500 on /login",
///     repoURL: URL(fileURLWithPath: "/path/to/repo"),
///     agentLaunch: .init(
///         executableURL: URL(fileURLWithPath: "/usr/bin/env"),
///         arguments: ["claude", "-p"]
///     )
/// )
/// let id = try await orchestrator.spawnWorker(spec)
/// ```
public struct WorkerSpec: Sendable, Equatable {
    /// A short human-readable name shown in the Fleet list.
    public let name: String

    /// The goal/prompt handed to the agent.
    public let prompt: String

    /// The git repository the worker operates on; a fresh worktree is branched
    /// from it for isolation.
    public let repoURL: URL

    /// How to launch the agent process inside the worktree.
    ///
    /// The orchestrator appends the prompt to the agent's arguments and sets the
    /// process working directory to the provisioned worktree, so the launch here
    /// describes only the executable, base arguments, and environment.
    public let agentLaunch: WorkerAgentLaunch

    /// Creates a `WorkerSpec`.
    ///
    /// - Parameters:
    ///   - name: A short human-readable name shown in the Fleet list.
    ///   - prompt: The goal/prompt handed to the agent.
    ///   - repoURL: The git repository the worker operates on.
    ///   - agentLaunch: How to launch the agent process inside the worktree.
    public init(
        name: String,
        prompt: String,
        repoURL: URL,
        agentLaunch: WorkerAgentLaunch
    ) {
        self.name = name
        self.prompt = prompt
        self.repoURL = repoURL
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
