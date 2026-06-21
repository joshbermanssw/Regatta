import Foundation
@testable import RegattaCore

// MARK: - FakeAgentScript

/// A value type that describes a sequence of steps for the fake-agent process to execute.
///
/// Rendered to the `OUT`/`ERR`/`SLEEP`/`EXIT` line-directive fixture format understood by
/// `fake-agent.sh`.
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

    var description: String {
        switch self {
        case .scriptNotFound(let detail):
            return "fake-agent.sh not found: \(detail)"
        }
    }
}

// MARK: - FakeAgent

/// Spawns `fake-agent.sh` via `Process` in the same way the real agent spawn path works in
/// `AgentSessionProcessStore.swift` — `executableURL`, `arguments`, `environment`, `Pipe` for
/// stdout/stderr, `process.run()`, drain pipes, `waitUntilExit()`, read `terminationStatus`.
///
/// Script location: resolved via `Bundle.module` so SwiftPM embeds the script as a test
/// resource. The script is invoked via `/bin/bash <script> <fixture>` so its executable bit
/// is irrelevant — no `chmod` needed after resource embedding.
///
/// Pipe-buffer safety: stdout/stderr are drained concurrently on background queues while the
/// process runs, so this harness is deadlock-safe for arbitrary output size — no pipe-buffer
/// ceiling applies. This helper is framework-agnostic — it throws `FakeAgentError` rather
/// than calling any test framework assertion APIs.
struct FakeAgent {
    // MARK: Script location

    /// URL of `fake-agent.sh`, resolved from the test bundle via `Bundle.module`.
    static var scriptURL: URL {
        get throws {
            guard let url = Bundle.module.url(forResource: "fake-agent", withExtension: "sh") else {
                throw FakeAgentError.scriptNotFound("Bundle.module has no resource named fake-agent.sh")
            }
            return url
        }
    }

    // MARK: Public API

    /// Spawns the fake agent once with the given script and returns the captured run result.
    ///
    /// - Parameter script: The script to execute.
    /// - Returns: A `FakeAgentRun` with stdout, stderr, and exit code.
    /// - Throws: `FakeAgentError` if the script is missing; any error from `Process.run()`.
    func run(_ script: FakeAgentScript) async throws -> FakeAgentRun {
        let scriptPath = try Self.scriptURL.path
        let fixturePath = try writeFixture(script)
        defer { try? FileManager.default.removeItem(atPath: fixturePath) }

        return try await spawnAndCapture(scriptPath: scriptPath, fixturePath: fixturePath)
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
    func loop(scripts: [FakeAgentScript], maxIterations: Int) async throws -> [FakeAgentRun] {
        guard !scripts.isEmpty else { return [] }
        var results: [FakeAgentRun] = []
        for i in 0..<maxIterations {
            let script = i < scripts.count ? scripts[i] : scripts[scripts.count - 1]
            let result = try await run(script)
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

    /// Spawns the script via `/bin/bash <script> <fixture>`, drains pipes concurrently,
    /// waits for exit, and returns the result.
    ///
    /// Invoking via `/bin/bash` means the resource's executable bit is irrelevant — SwiftPM
    /// may strip it when copying bundle resources and that is fine.
    ///
    /// Pipe-buffer safety: stdout and stderr are drained concurrently on background queues while
    /// the process runs, then we join with `group.wait()` after `waitUntilExit()`.  This prevents
    /// the classic pipe-buffer deadlock where a process blocks on a full pipe while the parent
    /// blocks in `waitUntilExit()` — the harness is safe for arbitrary output size.
    private func spawnAndCapture(scriptPath: String, fixturePath: String) async throws -> FakeAgentRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, fixturePath]
        // Provide a minimal, clean environment mirroring AgentSessionProcessStore spawn style.
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
        ]

        // Redirect child stdout/stderr to temp FILES, not Pipes. Under parallel
        // test execution (Swift Testing runs suites concurrently), Foundation's
        // Process pipe FDs can be inherited by a sibling test's spawned child, so
        // a pipe's write-end never closes and `readDataToEndOfFile()` deadlocks —
        // it passes locally but hangs on CI. A regular file has no inheritable
        // pipe write-end and cannot deadlock. stdin is /dev/null so a script that
        // reads stdin can't block either.
        let tmpDir = FileManager.default.temporaryDirectory
        let outURL = tmpDir.appendingPathComponent("fakeagent-out-\(UUID().uuidString)")
        let errURL = tmpDir.appendingPathComponent("fakeagent-err-\(UUID().uuidString)")
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

        // Launch inside the process-wide spawn gate so this `posix_spawn` cannot fire while another
        // launch's pipe fds are open-but-not-yet-CLOEXEC (the fd-inheritance hang behind issue #14).
        try await SubprocessSpawnGate.shared.run {
            try process.run()
        }
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()

        let stdout = (try? Data(contentsOf: outURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let stderr = (try? Data(contentsOf: errURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""

        return FakeAgentRun(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus
        )
    }
}
