public import Foundation

/// The captured result of running one shell command for a deterministic check.
///
/// A value type so a ``RegattaCommandRunning`` implementation can hand its
/// output to ``RegattaDeterministicLoopCondition`` without exposing any process
/// handles. `stdout` and `stderr` are decoded UTF-8 text (empty when the stream
/// produced nothing or could not be decoded).
public struct RegattaCommandResult: Equatable, Sendable {
    /// The process exit status (`0` on success).
    public let exitCode: Int32

    /// Everything the command wrote to standard output, decoded as UTF-8.
    public let stdout: String

    /// Everything the command wrote to standard error, decoded as UTF-8.
    public let stderr: String

    /// Creates a command result.
    ///
    /// - Parameters:
    ///   - exitCode: The process exit status.
    ///   - stdout: The decoded standard-output text.
    ///   - stderr: The decoded standard-error text.
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// A synchronous seam for running a deterministic check command in a directory.
///
/// The loop engine calls ``RegattaLoopCondition/evaluate(_:)`` synchronously, so
/// the deterministic condition needs a *synchronous* way to run its check. This
/// protocol is that seam: production uses ``RegattaSubprocessCommandRunner``
/// (a real `Process` whose output goes to files, never pipes — see the
/// `cmux-architecture` subprocess rule); tests inject a fake that returns canned
/// results with no spawn, so the evaluators can be tested without a real shell.
///
/// Conformers must be `Sendable` because the condition that holds one is shared
/// across the engine actor's iterations.
public protocol RegattaCommandRunning: Sendable {
    /// Runs `command` to completion in `directory` and returns its result.
    ///
    /// The command is executed through a login-free, non-interactive shell so a
    /// caller can pass an ordinary command line (e.g. `"swift test"` or
    /// `"echo hi | grep hi"`). Standard input is closed so the command can never
    /// block on a prompt.
    ///
    /// - Parameters:
    ///   - command: The shell command line to run.
    ///   - directory: The working directory the command runs in — for a loop
    ///     worker this is its isolated worktree path.
    /// - Returns: The captured ``RegattaCommandResult``.
    /// - Throws: An error if the command could not be spawned at all (a non-zero
    ///   exit is reported via ``RegattaCommandResult/exitCode``, not thrown).
    func run(command: String, in directory: URL) throws -> RegattaCommandResult
}
