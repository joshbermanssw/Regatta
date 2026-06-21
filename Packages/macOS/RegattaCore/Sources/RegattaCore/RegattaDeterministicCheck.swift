/// A deterministic, agent-agnostic exit check the loop runs after each iteration
/// to decide whether the goal is objectively met (issue #20).
///
/// Each case wraps a command (and, for ``outputMatches(command:pattern:)``, a
/// regular expression) supplied by the user. The check runs in the worker's
/// **worktree** and depends only on the command's exit status / output — never
/// on any model's text — so the same check works no matter which agent drove the
/// iteration. ``RegattaDeterministicLoopCondition`` evaluates these.
///
/// ```swift
/// let check = RegattaDeterministicCheck.testsPass(command: "swift test")
/// let condition = RegattaDeterministicLoopCondition(
///     check: check,
///     workingDirectory: worktree.path
/// )
/// ```
public enum RegattaDeterministicCheck: Equatable, Sendable {
    /// The project's test command passes (exits `0`).
    ///
    /// Semantically identical to ``commandExitsZero(command:)`` but named for the
    /// common "make the tests pass" goal so the UI can label it distinctly.
    ///
    /// - Parameter command: The test command line (e.g. `"swift test"`).
    case testsPass(command: String)

    /// An arbitrary command exits with status `0`.
    ///
    /// - Parameter command: The command line to run as the check.
    case commandExitsZero(command: String)

    /// A command runs and its combined output matches a regular expression.
    ///
    /// The check is satisfied when the regex finds a match anywhere in the
    /// command's stdout + stderr, regardless of the command's exit code — useful
    /// for "stop once the build log prints `BUILD SUCCEEDED`". An invalid regex
    /// makes the check fail (never match) rather than crash.
    ///
    /// - Parameters:
    ///   - command: The command line whose output is searched.
    ///   - pattern: An `NSRegularExpression`-syntax pattern to search for.
    case outputMatches(command: String, pattern: String)

    /// The command line this check runs.
    public var command: String {
        switch self {
        case .testsPass(let command),
             .commandExitsZero(let command),
             .outputMatches(let command, _):
            return command
        }
    }

    /// A short, stable label for the check kind, used in summaries and the UI.
    public var kindLabel: String {
        switch self {
        case .testsPass: return "tests-pass"
        case .commandExitsZero: return "command-exits-0"
        case .outputMatches: return "output-matches"
        }
    }
}
