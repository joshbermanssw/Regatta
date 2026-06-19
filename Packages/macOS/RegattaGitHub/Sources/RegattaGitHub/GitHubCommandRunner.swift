public import Foundation
import Darwin
import os

/// The production ``GitHubCommandRunning`` that shells out to the real `gh` CLI.
///
/// Resolves `gh` against `PATH` and a set of fallback directories so it works
/// in both app-bundle and standalone `swift test` contexts.
///
/// ```swift
/// let runner = GitHubCommandRunner()
/// let output = try await runner.run(["pr", "view", "--json", "statusCheckRollup", "--repo", "owner/repo", "123"])
/// ```
public struct GitHubCommandRunner: GitHubCommandRunning, Sendable {
    /// Seconds to wait for a `gh` invocation before terminating it.
    public static let defaultTimeout: TimeInterval = 30

    private let timeout: TimeInterval

    /// The default fallback directories searched when `gh` is not on `PATH`.
    public static let defaultFallbackDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    private let fallbackDirectories: [String]

    private static let timerQueue = DispatchQueue(label: "com.regatta.GitHubCommandRunner.timer")

    /// Creates a production command runner.
    /// - Parameters:
    ///   - timeout: Seconds to wait per invocation (default: 30).
    ///   - fallbackDirectories: Extra directories to search for `gh` when not on `PATH`.
    public init(
        timeout: TimeInterval = defaultTimeout,
        fallbackDirectories: [String] = defaultFallbackDirectories
    ) {
        self.timeout = timeout
        self.fallbackDirectories = fallbackDirectories
    }

    /// Runs `gh` with the given arguments and returns its standard output.
    ///
    /// - Throws: ``GitHubCommandError`` on non-zero exit, timeout, or launch failure.
    public func run(_ args: [String]) async throws -> String {
        let ghPath = resolvedGhPath()
        let process = Process()
        if ghPath == "gh" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh"] + args
        } else {
            process.executableURL = URL(fileURLWithPath: ghPath)
            process.arguments = args
        }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let localTimeout = self.timeout

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            // Mutable shared state between the termination handler and the deadline timer.
            // Guarded by OSAllocatedUnfairLock so no async/await is needed for the small
            // synchronous coordination between non-async callbacks — the lock carve-out
            // applies here (same pattern as CommandRunner in CmuxFoundation).
            let state = OSAllocatedUnfairLock(initialState: RunnerState())

            @Sendable func claimAndResume(_ result: Result<String, GitHubCommandError>) {
                let (won, timer): (Bool, (any DispatchSourceTimer)?) = state.withLock { s in
                    guard !s.resumed else { return (false, nil) }
                    s.resumed = true
                    let t = s.deadlineTimer
                    s.deadlineTimer = nil
                    return (true, t)
                }
                timer?.cancel()
                guard won else { return }
                switch result {
                case .success(let output):
                    continuation.resume(returning: output)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            do {
                try process.run()
            } catch {
                claimAndResume(.failure(.launchFailed(String(describing: error))))
                return
            }

            // Close write ends in the parent so readers see EOF when the child closes.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()

            process.terminationHandler = { @Sendable finished in
                let exitStatus = finished.terminationStatus
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8)

                if exitStatus == 0 {
                    guard let output = String(data: stdoutData, encoding: .utf8) else {
                        claimAndResume(.failure(.outputDecodingFailed))
                        return
                    }
                    claimAndResume(.success(output))
                } else {
                    claimAndResume(.failure(.nonZeroExit(exitStatus: exitStatus, stderr: stderr)))
                }
            }

            // Arm the deadline after a successful launch.
            let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
            timer.schedule(deadline: .now() + localTimeout)
            timer.setEventHandler { @Sendable in
                if process.isRunning {
                    process.terminate()
                }
                claimAndResume(.failure(.timedOut))
                timer.cancel()
            }

            let alreadyResumed = state.withLock { s -> Bool in
                if s.resumed { return true }
                s.deadlineTimer = timer
                return false
            }
            if alreadyResumed {
                timer.cancel()
            } else {
                timer.resume()
            }
        }
    }

    // MARK: Path resolution

    private func resolvedGhPath() -> String {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirs = pathEnv.split(separator: ":").map(String.init)
        let allDirs = pathDirs + fallbackDirectories
        for dir in allDirs {
            let candidate = dir + "/gh"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // Return bare "gh" — caller routes through /usr/bin/env.
        return "gh"
    }
}

// MARK: - Shared mutable run state

/// Shared state for the termination handler + deadline timer race in ``GitHubCommandRunner/run(_:)``.
private struct RunnerState {
    var resumed = false
    var deadlineTimer: (any DispatchSourceTimer)?
}
