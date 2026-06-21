public import Foundation

/// The production ``RegattaCommandRunning`` that runs a deterministic check via a
/// real `/bin/sh -c` subprocess inside a worker's worktree.
///
/// Output handling mirrors ``RegattaWorktreeManager``: the child's stdout and
/// stderr are redirected to temp **files**, never `Pipe`s. Under concurrent
/// spawns (parallel workers, or parallel tests), Foundation's `Process` pipe FDs
/// can be inherited by a sibling child so a pipe write-end never closes and a
/// read deadlocks — passing locally but hanging under load. A regular file has
/// no inheritable pipe write-end and cannot deadlock. Standard input is
/// `/dev/null` so a check command can never block on an interactive prompt.
///
/// `waitUntilExit()` is synchronous, which is exactly what the synchronous
/// ``RegattaLoopCondition/evaluate(_:)`` seam needs.
///
/// ## Usage
/// ```swift
/// let runner = RegattaSubprocessCommandRunner()
/// let result = try runner.run(command: "swift test", in: worktree.path)
/// if result.exitCode == 0 { /* tests passed */ }
/// ```
public struct RegattaSubprocessCommandRunner: RegattaCommandRunning {

    /// The absolute path of the shell used to interpret the command line.
    private let shellPath: String

    /// A minimal environment passed to the spawned shell.
    ///
    /// Defaults to a clean `PATH`/`HOME`/`TMPDIR` triple so a check behaves the
    /// same regardless of the caller's ambient environment.
    private let environment: [String: String]

    /// Creates a subprocess command runner.
    ///
    /// - Parameters:
    ///   - shellPath: The shell used to run the command line via `-c`.
    ///     Defaults to `/bin/sh`.
    ///   - environment: The environment for the spawned shell. Defaults to a
    ///     clean `PATH`/`HOME`/`TMPDIR` triple.
    public init(
        shellPath: String = "/bin/sh",
        environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
        ]
    ) {
        self.shellPath = shellPath
        self.environment = environment
    }

    /// Runs `command` via `<shell> -c <command>` in `directory`, capturing output
    /// from temp files, and returns the result.
    public func run(command: String, in directory: URL) throws -> RegattaCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = environment

        let tmpDir = FileManager.default.temporaryDirectory
        let outURL = tmpDir.appendingPathComponent("regatta-check-out-\(UUID().uuidString)")
        let errURL = tmpDir.appendingPathComponent("regatta-check-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        try process.run()
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()

        let stdout = (try? Data(contentsOf: outURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let stderr = (try? Data(contentsOf: errURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""

        return RegattaCommandResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}
