/// An error returned when a `gh` command invocation fails.
public enum GitHubCommandError: Error, Sendable, Equatable {
    /// The process exited with a non-zero status.
    /// - Parameters:
    ///   - exitStatus: The process exit code.
    ///   - stderr: Standard error output captured from `gh`, if any.
    case nonZeroExit(exitStatus: Int32, stderr: String?)
    /// The process exceeded its deadline and was terminated.
    case timedOut
    /// The process could not be launched.
    case launchFailed(String)
    /// The command returned output that could not be decoded as UTF-8.
    case outputDecodingFailed
    /// The JSON output could not be parsed into the expected model shape.
    case jsonDecodingFailed(String)
}
