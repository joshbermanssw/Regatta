public import Foundation

/// A value description of how to launch an agent process behind a ``PaneBridge``.
///
/// Mirrors the spawn shape of cmux's agent process path and `FakeAgent`:
/// an executable, its arguments, an environment, and the working directory the
/// process runs in. The orchestrator builds a `PaneSpec` from a provisioned
/// worktree plus the worker's agent launch and hands it to the bridge.
///
/// ## Example
/// ```swift
/// let spec = PaneSpec(
///     workingDirectory: worktree.path,
///     executableURL: URL(fileURLWithPath: "/usr/bin/env"),
///     arguments: ["claude", "-p", "fix the bug"],
///     environment: ["PATH": "/usr/bin:/bin"]
/// )
/// ```
public struct PaneSpec: Sendable, Equatable {
    /// The directory the process runs in (typically a worker's worktree root).
    public let workingDirectory: URL

    /// The executable to launch.
    public let executableURL: URL

    /// The arguments passed to the executable.
    public let arguments: [String]

    /// The environment the process runs with.
    public let environment: [String: String]

    /// Creates a `PaneSpec`.
    ///
    /// - Parameters:
    ///   - workingDirectory: The directory the process runs in.
    ///   - executableURL: The executable to launch.
    ///   - arguments: The arguments passed to the executable. Defaults to empty.
    ///   - environment: The environment the process runs with. Defaults to empty.
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
