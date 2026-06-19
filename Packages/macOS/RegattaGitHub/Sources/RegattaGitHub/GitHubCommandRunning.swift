/// The injection seam for running `gh` subcommands.
///
/// Production code uses ``GitHubCommandRunner``, which shells out to the real `gh`
/// CLI. Tests inject a ``FakeGitHubCommandRunner`` that returns canned JSON strings
/// without spawning any process, keeping tests hermetic and fast.
///
/// ```swift
/// let poller = GitHubPoller(commandRunner: GitHubCommandRunner())
/// // In tests:
/// let poller = GitHubPoller(commandRunner: FakeGitHubCommandRunner(responses: [...]))
/// ```
public protocol GitHubCommandRunning: Sendable {
    /// Runs `gh` with the given arguments and returns standard output.
    ///
    /// - Parameter args: The arguments to pass after `gh` (e.g. `["pr", "view", "--json", "statusCheckRollup"]`).
    /// - Returns: The captured standard output on success.
    /// - Throws: ``GitHubCommandError`` when the command exits non-zero, times out,
    ///   or fails to launch.
    func run(_ args: [String]) async throws -> String
}
