import Foundation
import RegattaFleet

/// The production ``WorktreePushing`` conformer: runs a real `git push` of a
/// worktree's committed `HEAD` to the pull request's head branch.
///
/// Used by ``GitPushActionExecutor`` once the ``AutonomyGate`` authorises a push
/// (immediately in auto mode, or after the user approves in staged mode). The
/// worker committed locally; this is the step that actually moves those commits to
/// GitHub — and it runs only via the gate, never by the agent directly, so the
/// staged-approval autonomy gate stays meaningful.
///
/// Subprocess discipline mirrors ``RegattaWorktreeManager`` / ``RegattaGitDiffProbe``:
/// stdout/stderr go to temp **files** (never `Pipe`s) and stdin is `/dev/null`, so
/// a concurrently-spawned sibling cannot inherit a pipe write-end and deadlock the
/// read, and `git push` can never block on an interactive credential prompt.
struct RegattaGitWorktreePusher: WorktreePushing {
    /// The remote to push to. Defaults to `origin`.
    private let remote: String

    init(remote: String = "origin") {
        self.remote = remote
    }

    func push(worktreePath: URL, branch: String) async throws {
        // `git -C <worktree> push <remote> HEAD:<branch>` pushes the worktree's
        // current commit to the PR head branch, regardless of the worktree's local
        // branch name (each worker uses a throwaway `regatta/worker-*` branch).
        try await runGit(
            arguments: ["-C", worktreePath.path, "push", remote, "HEAD:\(branch)"]
        )
    }

    /// Runs a git command, capturing output to temp files and throwing on a
    /// non-zero exit.
    private func runGit(arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let tmpDir = FileManager.default.temporaryDirectory
        let outURL = tmpDir.appendingPathComponent("regatta-push-out-\(UUID().uuidString)")
        let errURL = tmpDir.appendingPathComponent("regatta-push-err-\(UUID().uuidString)")
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

        let termination = PushProcessTermination()
        process.terminationHandler = { p in termination.complete(p.terminationStatus) }

        try process.run()
        let exitCode = await termination.wait()
        try? outHandle.close()
        try? errHandle.close()

        guard exitCode == 0 else {
            let stderr = (try? Data(contentsOf: errURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw RegattaGitPushError.pushFailed(exitCode: exitCode, stderr: stderr)
        }
    }
}

/// The error a ``RegattaGitWorktreePusher`` throws on a non-zero `git push`.
enum RegattaGitPushError: Error, Equatable {
    case pushFailed(exitCode: Int32, stderr: String)
}

/// One-shot resume guard for the push `Process` termination handler racing a
/// spawn failure. Mirrors the `NSLock` carve-out used by the diff probe.
private final class PushProcessTermination: @unchecked Sendable {
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
