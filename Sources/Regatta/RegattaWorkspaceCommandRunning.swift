import Foundation
import RegattaGitHub

/// The injection seam for running a `gh` subcommand inside a specific working
/// directory, so branch→PR resolution can infer the repository from the
/// workspace's git checkout the same way a human running `gh` in that folder
/// would.
///
/// ``RegattaWorkspaceCommandRunner`` is the production conformer (it shells out to
/// the real `gh` with the directory as the process's `currentDirectoryURL`). Tests
/// inject a stub returning canned JSON or throwing a canned ``GitHubCommandError``
/// with no process spawn.
protocol RegattaWorkspaceCommandRunning: Sendable {
    /// Runs `gh` with `args` inside `directory` and returns standard output.
    ///
    /// - Parameters:
    ///   - args: The arguments passed after `gh`.
    ///   - directory: The working directory `gh` runs in (a git checkout).
    /// - Returns: Captured standard output on success.
    /// - Throws: ``GitHubCommandError`` on non-zero exit, timeout, or launch failure.
    func run(_ args: [String], in directory: String) async throws -> String
}
