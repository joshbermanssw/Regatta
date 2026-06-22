public import Foundation

/// A ``RegattaDiffProbing`` that detects new changes via `git status --porcelain`
/// inside a worker's worktree.
///
/// Mirrors ``RegattaWorktreeManager``'s subprocess discipline: git's stdout and
/// stderr are redirected to temp **files**, not pipes, so a concurrently-spawned
/// sibling can never inherit a pipe write-end and deadlock the read (the CI
/// hazard called out in `RegattaWorktreeManager`). A non-empty porcelain status
/// means the iteration left uncommitted changes; an empty status is "dry".
public struct RegattaGitDiffProbe: RegattaDiffProbing {
    /// Creates a git-backed diff probe.
    public init() {}

    /// Returns `true` when `git status --porcelain` reports any change.
    ///
    /// - Parameter worktreePath: The worktree root to inspect.
    /// - Returns: `true` if the porcelain status is non-empty.
    /// - Throws: ``WorktreeError/gitCommandFailed(command:exitCode:stderr:)`` on
    ///   a non-zero git exit, or a file-system error setting up capture.
    public func hasUncommittedChanges(at worktreePath: URL) async throws -> Bool {
        let output = try await captureGit(
            arguments: ["-C", worktreePath.path, "status", "--porcelain"]
        )
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns `true` when the worktree's `HEAD` has commits not reachable from
    /// any other branch — i.e. the agent committed new work locally.
    ///
    /// `git rev-list --count HEAD --not --branches --exclude=<current>` counts the
    /// commits unique to the checked-out branch. A worker worktree is created with
    /// `git worktree add -b <branch>` forked from the repo's HEAD, so the agent's
    /// commits land only on `<branch>`; this count is `> 0` exactly when the agent
    /// produced new local commits (even though it left the worktree clean). When
    /// `HEAD` is detached or the branch cannot be resolved, the result is `false`.
    ///
    /// - Parameter worktreePath: The worktree root to inspect.
    /// - Returns: `true` if `HEAD` has at least one branch-unique commit.
    /// - Throws: ``WorktreeError/gitCommandFailed(command:exitCode:stderr:)`` on a
    ///   non-zero git exit, or a file-system error setting up capture.
    public func hasNewCommits(at worktreePath: URL) async throws -> Bool {
        let branch = try await captureGit(
            arguments: ["-C", worktreePath.path, "rev-parse", "--abbrev-ref", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // Detached HEAD ("HEAD") has no branch to exclude; treat as no new commits.
        guard !branch.isEmpty, branch != "HEAD" else { return false }

        // Count commits reachable from HEAD but from no branch other than the
        // checked-out one. `--exclude=<glob>` applies to the *next* `--branches`,
        // so it must precede it; placing it after silently excludes nothing.
        let output = try await captureGit(
            arguments: [
                "-C", worktreePath.path,
                "rev-list", "--count", "HEAD",
                "--not", "--exclude=\(branch)", "--branches",
            ]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return (Int(output) ?? 0) > 0
    }

    /// Runs a git command, captures stdout via a temp file, and returns it.
    ///
    /// Output goes to a regular file (never a `Pipe`) and stdin is `/dev/null`,
    /// matching ``RegattaWorktreeManager`` so concurrent spawns can't deadlock.
    private func captureGit(arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let tmpDir = FileManager.default.temporaryDirectory
        let outURL = tmpDir.appendingPathComponent("regatta-dry-out-\(UUID().uuidString)")
        let errURL = tmpDir.appendingPathComponent("regatta-dry-err-\(UUID().uuidString)")
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

        // One-shot resume guard for the termination handler racing a spawn
        // failure — the lock carve-out from RegattaWorktreeManager.
        let termination = DiffProbeProcessTermination()
        process.terminationHandler = { p in
            termination.complete(p.terminationStatus)
        }

        try process.run()
        let exitCode = await termination.wait()
        try? outHandle.close()
        try? errHandle.close()

        let stdout = (try? Data(contentsOf: outURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let stderr = (try? Data(contentsOf: errURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""

        guard exitCode == 0 else {
            throw WorktreeError.gitCommandFailed(
                command: "status",
                exitCode: exitCode,
                stderr: stderr
            )
        }

        return stdout
    }
}

// MARK: - DiffProbeProcessTermination

/// One-shot resume guard for a `Process` termination handler racing a spawn
/// failure. Uses `NSLock` per the cmux-architecture carve-out for a synchronous
/// compare-and-set called from a non-async callback: promoting this to an actor
/// would only add a `Task { await … }` hop to a fundamentally one-shot
/// compare-and-set.
private final class DiffProbeProcessTermination: @unchecked Sendable {
    // NSLock guards a one-shot Bool flag + optional continuation — not ongoing
    // domain state. Approved carve-out per cmux-architecture.
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func complete(_ status: Int32) {
        let resume: CheckedContinuation<Int32, Never>?
        lock.lock()
        if let pending = continuation {
            continuation = nil
            resume = pending
        } else {
            self.status = status
            resume = nil
        }
        lock.unlock()
        resume?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completed: Int32?
            lock.lock()
            if let status {
                completed = status
            } else {
                self.continuation = continuation
                completed = nil
            }
            lock.unlock()
            if let completed {
                continuation.resume(returning: completed)
            }
        }
    }
}
