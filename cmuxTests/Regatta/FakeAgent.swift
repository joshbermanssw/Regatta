import Foundation

// MARK: - FakeAgentScript

/// A value type that describes a sequence of steps for the fake-agent process to execute.
///
/// Rendered to the `OUT`/`ERR`/`SLEEP`/`EXIT` line-directive fixture format understood by
/// `fake-agent.sh`.  Keep fixture content small to avoid pipe-buffer deadlocks (the helper
/// reads stdout/stderr after `waitUntilExit`).
struct FakeAgentScript {
    /// A single step in a fake-agent script.
    enum Step {
        /// Emit `text` + newline on stdout.
        case out(String)
        /// Emit `text` + newline on stderr.
        case err(String)
        /// Pause for `ms` milliseconds.
        case sleepMs(Int)
    }

    /// The steps to execute, in order.
    var steps: [Step]
    /// The process exit code (appended as an `EXIT` directive).  Defaults to `0`.
    var exitCode: Int32 = 0

    /// Renders the script to the line-directive fixture text consumed by `fake-agent.sh`.
    func fixtureText() -> String {
        var lines: [String] = []
        for step in steps {
            switch step {
            case .out(let text):
                lines.append("OUT \(text)")
            case .err(let text):
                lines.append("ERR \(text)")
            case .sleepMs(let ms):
                lines.append("SLEEP \(ms)")
            }
        }
        lines.append("EXIT \(exitCode)")
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - FakeAgentRun

/// The captured result of a single fake-agent process run.
struct FakeAgentRun {
    /// All text written to stdout, decoded as UTF-8.
    let stdout: String
    /// All text written to stderr, decoded as UTF-8.
    let stderr: String
    /// The process termination status.
    let exitCode: Int32
}

// MARK: - FakeAgentError

/// Errors thrown by `FakeAgent`.
enum FakeAgentError: Error, CustomStringConvertible {
    case scriptNotFound(String)
    case scriptNotExecutable(String)

    var description: String {
        switch self {
        case .scriptNotFound(let path):
            return "fake-agent.sh not found at \(path)"
        case .scriptNotExecutable(let path):
            return "fake-agent.sh is not executable at \(path)"
        }
    }
}

// MARK: - FakeAgent

/// Spawns `fake-agent.sh` via `Process` in the same way the real agent spawn path works in
/// `AgentSessionProcessStore.swift` — `executableURL`, `arguments`, `environment`, `Pipe` for
/// stdout/stderr, `process.run()`, drain pipes, `waitUntilExit()`, read `terminationStatus`.
///
/// Script location: resolved at compile time relative to this Swift source file using `#filePath`,
/// so the script is always read from its on-disk source location on the same machine that
/// compiled the tests — no Xcode bundle embedding needed.
///
/// Pipe-buffer note: stdout/stderr are drained **after** `waitUntilExit()`.  This is safe only
/// while fixture output is small (a few KB, well under the 64 KB macOS pipe buffer).
/// Keep all fixtures tiny. This helper is framework-agnostic — it throws `FakeAgentError` rather
/// than calling any test framework assertion APIs.
struct FakeAgent {
    // MARK: Script location

    /// URL of `fake-agent.sh`, resolved relative to this file at compile time.
    static var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fake-agent.sh")
    }

    // MARK: Public API

    /// Spawns the fake agent once with the given script and returns the captured run result.
    ///
    /// - Parameter script: The script to execute.
    /// - Returns: A `FakeAgentRun` with stdout, stderr, and exit code.
    /// - Throws: `FakeAgentError` if the script is missing or not executable;
    ///           any error from `Process.run()`.
    func run(_ script: FakeAgentScript) throws -> FakeAgentRun {
        let scriptURL = Self.scriptURL
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw FakeAgentError.scriptNotFound(scriptURL.path)
        }
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw FakeAgentError.scriptNotExecutable(scriptURL.path)
        }

        let fixturePath = try writeFixture(script)
        defer { try? FileManager.default.removeItem(atPath: fixturePath) }

        return try spawnAndCapture(scriptURL: scriptURL, fixturePath: fixturePath)
    }

    /// Spawns the fake agent once per element in `scripts`, stopping early when a run exits `0`,
    /// and never exceeding `maxIterations` total runs.
    ///
    /// This is the minimal harness loop so iteration behavior can be asserted deterministically
    /// before the real loop engine (issue #19) is built.
    ///
    /// - Parameters:
    ///   - scripts: Per-iteration scripts.  Index `i` is used for iteration `i`.  If `scripts`
    ///     is shorter than `maxIterations` the last script is repeated.
    ///   - maxIterations: Hard cap on the number of spawns.
    /// - Returns: The per-iteration `FakeAgentRun` results (length ≤ `maxIterations`).
    func loop(scripts: [FakeAgentScript], maxIterations: Int) throws -> [FakeAgentRun] {
        guard !scripts.isEmpty else { return [] }
        var results: [FakeAgentRun] = []
        for i in 0..<maxIterations {
            let script = i < scripts.count ? scripts[i] : scripts[scripts.count - 1]
            let result = try run(script)
            results.append(result)
            if result.exitCode == 0 {
                break
            }
        }
        return results
    }

    // MARK: Private helpers

    /// Writes the fixture text to a unique temp file and returns its path.
    private func writeFixture(_ script: FakeAgentScript) throws -> String {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("fake-agent-fixture-\(UUID().uuidString).txt").path
        try script.fixtureText().write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Spawns the script, waits for exit, drains pipes, and returns the result.
    ///
    /// Pipe-buffer safety: we call `waitUntilExit()` first and then drain the pipes synchronously.
    /// This is safe for small fixture outputs (well under the 64 KB pipe buffer on macOS).
    private func spawnAndCapture(scriptURL: URL, fixturePath: String) throws -> FakeAgentRun {
        let process = Process()
        process.executableURL = scriptURL
        process.arguments = [fixturePath]
        // Provide a minimal, clean environment mirroring AgentSessionProcessStore spawn style.
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return FakeAgentRun(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus
        )
    }
}
