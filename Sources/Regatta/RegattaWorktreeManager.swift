import Foundation

/// Manages isolated git worktrees for parallel Regatta workers.
///
/// Each worker gets its own worktree branched off the target repository so
/// concurrent agents never collide on the same working tree. The actor owns
/// all mutable state (the workerID → worktree map) and runs every git
/// subprocess through async/await — no locks, no `@Published`.
///
/// ## Usage
/// ```swift
/// let manager = RegattaWorktreeManager(baseDirectory: myTempDir)
/// let worktree = try await manager.createWorktree(
///     forWorker: "worker-1",
///     repoURL: URL(fileURLWithPath: "/path/to/repo"),
///     branch: "regatta/worker-1"
/// )
/// // … do work …
/// try await manager.cleanup(forWorker: "worker-1")
/// ```
actor RegattaWorktreeManager {

    // MARK: - State

    private var worktrees: [String: RegattaWorktree] = [:]
    private let baseDirectory: URL

    // MARK: - Init

    /// Creates a manager whose worktrees live under `baseDirectory`.
    ///
    /// - Parameter baseDirectory: Root directory under which each worker's
    ///   worktree subdirectory is created (e.g. `<base>/<sanitizedWorkerID>`).
    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    // MARK: - Factory

    /// Returns a sensible default base directory under Application Support.
    ///
    /// The directory is `~/Library/Application Support/Regatta/worktrees`.
    /// It is not created on disk until the manager first provisions a worktree.
    static func defaultBaseDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Regatta", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
    }

    // MARK: - Public API

    /// Provisions a new git worktree for the given worker.
    ///
    /// - Parameters:
    ///   - workerID: A unique identifier for the worker. The worktree directory
    ///     is named after a sanitized version of this ID.
    ///   - repoURL: The root of the source git repository.
    ///   - branch: The branch name to create in the worktree (`-b <branch>`).
    ///     If a branch with this name already exists in the repo, git will fail
    ///     with ``WorktreeError/gitCommandFailed(command:exitCode:stderr:)`` —
    ///     callers should use a unique branch name (e.g. derived from `workerID`
    ///     plus a timestamp or UUID).
    /// - Returns: The newly created ``RegattaWorktree``.
    /// - Throws: ``WorktreeError/notAGitRepository`` if `repoURL` is not a git
    ///   repo; ``WorktreeError/gitCommandFailed(command:exitCode:stderr:)`` if
    ///   git exits non-zero; or a file-system error if directory creation fails.
    func createWorktree(
        forWorker workerID: String,
        repoURL: URL,
        branch: String
    ) async throws -> RegattaWorktree {
        guard worktrees[workerID] == nil else {
            throw WorktreeError.gitCommandFailed(
                command: "worktree add",
                exitCode: -1,
                stderr: "A worktree is already tracked for worker '\(workerID)'. Clean it up first."
            )
        }

        // Validate that repoURL is a git repository.
        try await runGit(
            arguments: ["-C", repoURL.path, "rev-parse", "--is-inside-work-tree"],
            failsWith: .notAGitRepository
        )

        // Build worktree path.
        let sanitized = sanitize(workerID: workerID)
        let worktreePath = baseDirectory.appendingPathComponent(sanitized, isDirectory: true)

        // Ensure the base directory exists.
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )

        // Create the worktree on a new branch.
        try await runGit(
            arguments: ["-C", repoURL.path, "worktree", "add", "-b", branch, worktreePath.path]
        )

        let worktree = RegattaWorktree(
            workerID: workerID,
            path: worktreePath,
            branch: branch,
            repoURL: repoURL
        )
        worktrees[workerID] = worktree
        return worktree
    }

    /// Returns the worktree currently tracked for the given worker, or `nil`.
    func worktree(forWorker workerID: String) -> RegattaWorktree? {
        worktrees[workerID]
    }

    /// Returns a snapshot of all currently tracked worktrees.
    func allWorktrees() -> [RegattaWorktree] {
        Array(worktrees.values)
    }

    /// Cleans up the worktree for the given worker.
    ///
    /// Before deletion the manager checks `git status --porcelain` inside the
    /// worktree. If the worktree is dirty and `force` is `false`, this throws
    /// ``WorktreeError/worktreeDirty(path:)`` without touching the disk. If
    /// `force` is `true` (or the worktree is clean), the worktree directory is
    /// removed and the worker mapping is dropped.
    ///
    /// - Parameters:
    ///   - workerID: The worker whose worktree should be removed.
    ///   - force: If `true`, remove even when there are uncommitted changes.
    /// - Throws: ``WorktreeError/noWorktreeForWorker(_:)`` if no mapping
    ///   exists; ``WorktreeError/worktreeDirty(path:)`` if dirty and `force`
    ///   is `false`; ``WorktreeError/gitCommandFailed(command:exitCode:stderr:)``
    ///   on git errors.
    func cleanup(forWorker workerID: String, force: Bool = false) async throws {
        guard let worktree = worktrees[workerID] else {
            throw WorktreeError.noWorktreeForWorker(workerID)
        }

        // Safety guard: check for uncommitted changes in the worktree.
        let statusOutput = try await captureGit(
            arguments: ["-C", worktree.path.path, "status", "--porcelain"]
        )
        let isDirty = !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if isDirty && !force {
            throw WorktreeError.worktreeDirty(path: worktree.path)
        }

        // Remove the worktree from the repo's worktree list and from disk.
        var removeArgs = ["-C", worktree.repoURL.path, "worktree", "remove"]
        if force {
            removeArgs.append("--force")
        }
        removeArgs.append(worktree.path.path)
        try await runGit(arguments: removeArgs)

        worktrees.removeValue(forKey: workerID)
    }

    /// Cleans up all tracked worktrees.
    ///
    /// - Parameter force: Passed through to each ``cleanup(forWorker:force:)`` call.
    func cleanupAll(force: Bool = false) async throws {
        for workerID in Array(worktrees.keys) {
            try await cleanup(forWorker: workerID, force: force)
        }
    }

    // MARK: - Private git helpers

    /// Runs a git command, throwing a specific error when git exits non-zero
    /// (used for `rev-parse`-style validation where the exact exit reason maps
    /// to a domain error).
    private func runGit(arguments: [String], failsWith overrideError: WorktreeError) async throws {
        do {
            _ = try await captureGit(arguments: arguments)
        } catch {
            throw overrideError
        }
    }

    /// Runs a git command discarding output; throws
    /// ``WorktreeError/gitCommandFailed(command:exitCode:stderr:)`` on non-zero exit.
    private func runGit(arguments: [String]) async throws {
        _ = try await captureGit(arguments: arguments)
    }

    /// Runs a git command, captures stdout, and returns it as a `String`.
    ///
    /// Stdout and stderr are drained concurrently on detached tasks before
    /// `waitUntilExit()` to avoid pipe-buffer deadlock when output is large.
    /// Throws ``WorktreeError/gitCommandFailed(command:exitCode:stderr:)`` if
    /// git exits with a non-zero status.
    private func captureGit(arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // One-shot termination guard: the Process termination handler races
        // with any spawn failure to resume one continuation exactly once.
        // Uses a lock per the cmux-architecture carve-out for synchronous
        // compare-and-set over a tiny flag — an actor would add unnecessary
        // Task/await hops to what is fundamentally synchronous.
        let termination = WorktreeProcessTermination()
        process.terminationHandler = { p in
            termination.complete(p.terminationStatus)
        }

        try process.run()

        // Drain both pipes concurrently on detached tasks keyed by their raw
        // file descriptor (Int32 is Sendable; FileHandle is not, so we must
        // not capture the Pipe or FileHandle objects directly).
        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor

        async let outData: Data = Task.detached(priority: .utility) {
            WorktreePipeDrainer.drain(fileDescriptor: outFD)
        }.value

        async let errData: Data = Task.detached(priority: .utility) {
            WorktreePipeDrainer.drain(fileDescriptor: errFD)
        }.value

        let exitCode = await termination.wait()
        let (stdout, stderr) = await (outData, errData)

        // Pick a human-readable command label for the error.
        let commandLabel = arguments
            .drop(while: { $0 == "-C" || (!$0.hasPrefix("-") && $0.contains("/")) })
            .first(where: { !$0.hasPrefix("-") })
            ?? arguments.first
            ?? "git"

        guard exitCode == 0 else {
            let stderrText = String(data: stderr, encoding: .utf8) ?? ""
            throw WorktreeError.gitCommandFailed(
                command: commandLabel,
                exitCode: exitCode,
                stderr: stderrText
            )
        }

        return String(data: stdout, encoding: .utf8) ?? ""
    }

    /// Sanitizes a worker ID to a safe directory name component.
    private func sanitize(workerID: String) -> String {
        workerID
            .components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
    }
}

// MARK: - WorktreeProcessTermination

/// One-shot resume guard for a `Process` termination handler racing any spawn
/// failure. Uses `NSLock` per the cmux-architecture carve-out for a
/// synchronous compare-and-set called from non-async callbacks: the
/// termination handler is synchronous; promoting this to an actor would only
/// add a `Task { await … }` hop and reentrancy surface to what is
/// fundamentally a one-shot compare-and-set.
private final class WorktreeProcessTermination: @unchecked Sendable {
    // NSLock guards a one-shot Bool flag + optional continuation — not
    // ongoing domain state. Approved carve-out per cmux-architecture.
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

// MARK: - WorktreePipeDrainer

/// Drains a file descriptor to end-of-file and returns the accumulated data.
///
/// Called from a detached `Task` to avoid pipe-buffer deadlock. The fd is
/// `Int32` (Sendable) so we can safely capture it across task boundaries
/// without wrapping a non-Sendable `FileHandle`.
enum WorktreePipeDrainer {
    static func drain(fileDescriptor fd: Int32) -> Data {
        // Wrap the raw fd — closeOnDealloc: false so we don't double-close
        // the fd that the Pipe still owns.
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var result = Data()
        while true {
            let chunk: Data
            do {
                // read(upToCount:) returns nil on EOF on older SDKs; empty on newer.
                if let d = try handle.read(upToCount: 65536), !d.isEmpty {
                    chunk = d
                } else {
                    break
                }
            } catch {
                break
            }
            result.append(chunk)
        }
        return result
    }
}
