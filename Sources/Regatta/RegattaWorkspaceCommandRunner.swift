import Foundation
import os
import RegattaGitHub

/// The production ``RegattaWorkspaceCommandRunning`` that shells out to the real
/// `gh` CLI inside a given working directory.
///
/// Resolves `gh` against `PATH` plus the standard Homebrew/MacPorts fallbacks
/// (matching ``GitHubCommandRunner``) so it works in both app-bundle and
/// standalone `swift test` contexts, and runs it with `currentDirectoryURL` set to
/// the workspace so `gh` infers the repository from that checkout's git remote.
struct RegattaWorkspaceCommandRunner: RegattaWorkspaceCommandRunning, Sendable {
    /// Seconds to wait for a `gh` invocation before terminating it.
    static let defaultTimeout: TimeInterval = 20

    private let timeout: TimeInterval
    private let fallbackDirectories: [String]

    /// Creates a production workspace command runner.
    ///
    /// - Parameters:
    ///   - timeout: Seconds to wait per invocation (default: 20).
    ///   - fallbackDirectories: Extra directories to search for `gh` when not on
    ///     `PATH` (defaults to the Homebrew/MacPorts paths).
    init(
        timeout: TimeInterval = defaultTimeout,
        fallbackDirectories: [String] = GitHubCommandRunner.defaultFallbackDirectories
    ) {
        self.timeout = timeout
        self.fallbackDirectories = fallbackDirectories
    }

    func run(_ args: [String], in directory: String) async throws -> String {
        let ghPath = resolvedGhPath()
        let process = Process()
        if ghPath == "gh" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh"] + args
        } else {
            process.executableURL = URL(fileURLWithPath: ghPath)
            process.arguments = args
        }
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let localTimeout = self.timeout

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            // Lock carve-out (CLAUDE.md): a synchronous one-shot resume guard
            // shared between the termination handler and the deadline timer, the
            // same pattern as GitHubCommandRunner. Promoting to an actor would only
            // add await hops to non-async callbacks.
            let state = OSAllocatedUnfairLock(initialState: RunState())

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
                case .success(let output): continuation.resume(returning: output)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            do {
                try process.run()
            } catch {
                claimAndResume(.failure(.launchFailed(String(describing: error))))
                return
            }

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

            let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
            timer.schedule(deadline: .now() + localTimeout)
            timer.setEventHandler { @Sendable in
                if process.isRunning { process.terminate() }
                claimAndResume(.failure(.timedOut))
                timer.cancel()
            }

            let alreadyResumed = state.withLock { s -> Bool in
                if s.resumed { return true }
                s.deadlineTimer = timer
                return false
            }
            if alreadyResumed { timer.cancel() } else { timer.resume() }
        }
    }

    private static let timerQueue = DispatchQueue(label: "com.regatta.RegattaWorkspaceCommandRunner.timer")

    private func resolvedGhPath() -> String {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirs = pathEnv.split(separator: ":").map(String.init)
        for dir in pathDirs + fallbackDirectories {
            let candidate = dir + "/gh"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "gh"
    }
}

/// Shared state for the termination-handler / deadline-timer resume race in
/// ``RegattaWorkspaceCommandRunner/run(_:in:)``.
private struct RunState {
    var resumed = false
    var deadlineTimer: (any DispatchSourceTimer)?
}
