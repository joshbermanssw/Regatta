public import Foundation

/// A value description of an agent process to run in a pane.
///
/// A ``PaneSpec`` is the input to ``PaneBridge/spawn(_:)``. It is a pure `Sendable` value with
/// no live resources, so it can be constructed off the main actor, logged, and replayed.
///
/// ## Usage
/// ```swift
/// let spec = PaneSpec(
///     workingDirectory: worktree.path,
///     executableURL: URL(fileURLWithPath: "/usr/bin/env"),
///     arguments: ["claude", "--print", "fix the failing test"],
///     environment: ["PATH": "/usr/bin:/bin:/usr/local/bin"]
/// )
/// let handle = try await bridge.spawn(spec)
/// ```
public struct PaneSpec: Sendable, Equatable {
    /// The working directory the agent runs in (e.g. a worker's git worktree root).
    public let workingDirectory: URL

    /// The executable to launch.
    ///
    /// For a CLI coding agent this is typically `/usr/bin/env` (with the agent binary as the
    /// first argument) or the absolute path to the agent binary itself.
    public let executableURL: URL

    /// The arguments passed to ``executableURL``.
    public let arguments: [String]

    /// The environment for the spawned process.
    ///
    /// When empty the implementation supplies a minimal default environment. Callers that need
    /// a specific `PATH`, `HOME`, or agent credentials should populate this explicitly.
    public let environment: [String: String]

    /// Creates a pane specification.
    ///
    /// - Parameters:
    ///   - workingDirectory: Directory the agent runs in.
    ///   - executableURL: Executable to launch.
    ///   - arguments: Arguments passed to the executable. Defaults to none.
    ///   - environment: Environment for the process. Defaults to empty, in which case the
    ///     implementation supplies a minimal default environment.
    public init(
        workingDirectory: URL,
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.workingDirectory = workingDirectory
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }
}
