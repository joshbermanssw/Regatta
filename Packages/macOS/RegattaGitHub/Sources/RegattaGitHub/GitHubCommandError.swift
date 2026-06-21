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

    /// Whether this error is a `gh` authentication failure (e.g. an expired or
    /// missing token) that a human must resolve before polling can resume
    /// (issue #35). Detected from `gh`'s stderr on a non-zero exit.
    public var isAuthFailure: Bool {
        guard case .nonZeroExit(_, let stderr) = self, let stderr else { return false }
        let lowered = stderr.lowercased()
        return lowered.contains("authentication")
            || lowered.contains("not logged in")
            || lowered.contains("gh auth login")
            || lowered.contains("bad credentials")
            || lowered.contains("401")
            || lowered.contains("requires authentication")
    }

    /// Whether this error is a GitHub API rate-limit / abuse-detection response
    /// that the shepherd should back off from before retrying (issue #35).
    /// Detected from `gh`'s stderr on a non-zero exit.
    public var isRateLimited: Bool {
        guard case .nonZeroExit(_, let stderr) = self, let stderr else { return false }
        let lowered = stderr.lowercased()
        return lowered.contains("rate limit")
            || lowered.contains("ratelimit")
            || lowered.contains("api rate limit exceeded")
            || lowered.contains("secondary rate limit")
            || lowered.contains("403")
            || lowered.contains("retry-after")
    }

    /// Whether this error should make the shepherd *pause + back off* rather than
    /// retry on the normal interval — i.e. an auth or rate-limit failure.
    public var shouldPauseShepherd: Bool {
        isAuthFailure || isRateLimited
    }
}
