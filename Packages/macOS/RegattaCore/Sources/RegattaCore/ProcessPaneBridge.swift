public import Foundation

/// The default, host-independent ``PaneBridge`` that runs an agent as a subprocess.
///
/// `ProcessPaneBridge` spawns the agent with `Process`, streams stdout and stderr incrementally
/// as ``PaneOutputEvent`` values, and terminates the process cleanly on request. It owns no UI
/// and depends on no host pane layer, so it is the implementation used by the fake-agent test
/// harness (issue #10) and by headless CI. A cmux/Ghostty-backed bridge conforms to the same
/// ``PaneBridge`` protocol; see `PaneBridge.md` for the documented integration seam.
///
/// All mutable state (the id → running-process map) lives in this actor; there are no locks and
/// no `@Published`. Incremental pipe reads use `DispatchSource` read sources confined behind the
/// `AsyncStream` surface — callers never see them. A ``PaneTerminationCoordinator`` ensures the
/// terminal event is emitted only after both pipes drain, so trailing output is never lost.
///
/// ## Usage
/// ```swift
/// let bridge = ProcessPaneBridge()
/// let handle = try await bridge.spawn(spec)
/// for await event in handle.output { /* … */ }
/// ```
public actor ProcessPaneBridge: PaneBridge {

    /// A live process retained until it finishes, plus a teardown hook used by ``terminate(_:)``.
    private struct Running {
        let process: Process
        /// Forces stream completion when the process is killed: cancels the pipe drainers (closing
        /// our read ends so EOF fires even if a grandchild still holds the write end open) and
        /// feeds the coordinator a terminal status. Idempotent with natural exit.
        let forceFinish: @Sendable (Int32) -> Void
    }

    /// Currently running panes, keyed by handle id.
    private var running: [PaneHandle.ID: Running] = [:]

    /// Creates a process-backed pane bridge.
    public init() {}

    // MARK: - PaneBridge

    public func spawn(_ spec: PaneSpec) async throws -> PaneHandle {
        let id = PaneHandle.ID()

        // The emitter owns the AsyncStream continuation and guarantees one terminal event.
        let emitter = PaneOutputEmitter()
        let stream = AsyncStream<PaneOutputEvent> { continuation in
            emitter.attach(continuation)
        }

        // Finish the stream only after stdout EOF + stderr EOF + process exit have all arrived,
        // so trailing output is delivered before `.terminated`.
        let coordinator = PaneTerminationCoordinator { code in
            emitter.finish(code: code)
        }

        // Launch, retrying a transient `EBADF` ("Bad file descriptor"). Foundation's `Process.run()`
        // walks the process fd table while building the child; under heavy concurrent spawning a
        // sibling launch's fd close can race that walk and surface a one-off `EBADF` even though the
        // spec is valid. Each attempt builds a fresh `Process` + pipes inside the spawn gate, so a
        // retry starts from a clean fd state. Non-transient failures (bad executable path, etc.)
        // throw immediately.
        let launched: (process: Process, drainers: (stdout: PaneStreamDrainer, stderr: PaneStreamDrainer))
        do {
            launched = try await Self.launchWithRetry(
                spec: spec,
                emitter: emitter,
                coordinator: coordinator
            )
        } catch {
            // Spawn failed: complete the stream so any consumer already iterating it unblocks. Any
            // drainers created on the failed attempt tear down via their own deinit.
            emitter.finish(code: -1)
            throw PaneBridgeError.spawnFailed(String(describing: error))
        }
        let process = launched.process
        let drainers = launched.drainers

        let stdoutDrain = drainers.stdout
        let stderrDrain = drainers.stderr
        stdoutDrain.resume()
        stderrDrain.resume()

        let forceFinish: @Sendable (Int32) -> Void = { code in
            // Cancel the drainers to release our read fds (a grandchild may still hold the pipe
            // write end open), and complete the stream immediately rather than waiting on the
            // drainers' async EOF callbacks — which a lingering grandchild could delay.
            stdoutDrain.cancel()
            stderrDrain.cancel()
            coordinator.forceComplete(code)
        }
        running[id] = Running(process: process, forceFinish: forceFinish)

        // Untrack the pane once its stream finishes, regardless of cause (natural exit or
        // terminate()), so terminate() of a finished id reports `unknownHandle`.
        Task { [weak self] in
            await emitter.waitUntilFinished()
            await self?.untrack(id)
        }

        return PaneHandle(id: id, output: stream)
    }

    public func terminate(_ id: PaneHandle.ID) async throws {
        guard let entry = running[id] else {
            throw PaneBridgeError.unknownHandle(id)
        }
        // Drop tracking eagerly so a second terminate() of the same id reports `unknownHandle`.
        running.removeValue(forKey: id)
        if entry.process.isRunning {
            entry.process.terminate()
        }
        // Force stream completion: cancelling the drainers closes our read ends so EOF fires even
        // when a grandchild (e.g. a `sleep` spawned by the agent shell) still holds the pipe write
        // end open. The coordinator finishes the stream exactly once; a later natural-exit signal
        // is a no-op. SIGTERM is the status reported for a killed pane.
        entry.forceFinish(SIGTERM)
    }

    public func isRunning(_ id: PaneHandle.ID) -> Bool {
        guard let entry = running[id] else { return false }
        return entry.process.isRunning
    }

    // MARK: - Private

    /// Removes the tracking entry for a finished pane.
    private func untrack(_ id: PaneHandle.ID) {
        running.removeValue(forKey: id)
    }

    /// Launches the agent, retrying a transient `EBADF` from a concurrent fd-table race.
    ///
    /// - Parameters:
    ///   - spec: The pane spec to launch.
    ///   - emitter: The output emitter the drainers feed.
    ///   - coordinator: The termination coordinator the drainers + exit signal feed.
    /// - Returns: The running process plus its two pipe drainers (not yet resumed).
    /// - Throws: The last launch error if every attempt fails, or any non-transient error at once.
    private static func launchWithRetry(
        spec: PaneSpec,
        emitter: PaneOutputEmitter,
        coordinator: PaneTerminationCoordinator
    ) async throws -> (process: Process, drainers: (stdout: PaneStreamDrainer, stderr: PaneStreamDrainer)) {
        let maxAttempts = 5
        var lastError: (any Error)?
        for attempt in 1...maxAttempts {
            do {
                return try await launchOnce(spec: spec, emitter: emitter, coordinator: coordinator)
            } catch {
                lastError = error
                // Only a transient bad-fd race is worth retrying; anything else is a real failure.
                guard Self.isTransientSpawnError(error), attempt < maxAttempts else { throw error }
            }
        }
        throw lastError ?? PaneBridgeError.spawnFailed("unknown spawn failure")
    }

    /// Performs one launch attempt: create pipes, mark them close-on-exec, wire the drainers and
    /// termination handler, run the process, and close the parent's pipe write ends — all inside the
    /// process-wide spawn gate.
    ///
    /// The gate serializes the fd-table-mutating section so no concurrent launch is mid-`posix_spawn`
    /// while these pipe fds are open-but-not-yet-CLOEXEC — the inheritance window behind the
    /// headless-CI hang (issue #14). Closing the parent's write ends right after `run()` is what
    /// actually guarantees the read end reaches EOF when the child exits: Foundation's `Pipe` keeps
    /// the parent-side write handle open, so leaving it open makes the *parent* a permanent writer
    /// and the drainer's `read()` never returns 0. Drainers are returned un-resumed so the caller can
    /// resume them outside the gate (a long-lived child must not block other launches).
    ///
    /// - Returns: The running process and its two un-resumed drainers.
    /// - Throws: Any error from `Process.run()`.
    private static func launchOnce(
        spec: PaneSpec,
        emitter: PaneOutputEmitter,
        coordinator: PaneTerminationCoordinator
    ) async throws -> (process: Process, drainers: (stdout: PaneStreamDrainer, stderr: PaneStreamDrainer)) {
        try await SubprocessSpawnGate.shared.run {
            let process = Process()
            process.executableURL = spec.executableURL
            process.arguments = spec.arguments
            process.currentDirectoryURL = spec.workingDirectory
            process.environment = spec.environment.isEmpty ? Self.defaultEnvironment() : spec.environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            Self.setCloseOnExec(stdoutPipe)
            Self.setCloseOnExec(stderrPipe)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Drain both pipes incrementally. Each drainer owns its read fd and closes it on cancel,
            // then reports EOF to the coordinator. DispatchSource is the sanctioned low-level
            // primitive for streaming pipe I/O (cmux-architecture carve-out), hidden behind the
            // AsyncStream.
            let stdoutDrain = PaneStreamDrainer(
                readHandle: stdoutPipe.fileHandleForReading,
                onChunk: { emitter.yield(.stdout($0)) },
                onEOF: { coordinator.stdoutFinished() }
            )
            let stderrDrain = PaneStreamDrainer(
                readHandle: stderrPipe.fileHandleForReading,
                onChunk: { emitter.yield(.stderr($0)) },
                onEOF: { coordinator.stderrFinished() }
            )

            process.terminationHandler = { proc in
                // Record the exit code, then complete each drainer via `finishAfterExit()`. The child
                // is gone and the parent's write ends are closed (below), so all output is already in
                // the pipe buffer; `finishAfterExit()` reads it (ordered after pending reads, so no
                // byte is lost) and then fires EOF. This completes the stream even in the rare case a
                // stray inherited write-end would keep the pipe open and defer natural EOF forever —
                // the headless-CI hang (issue #14) — while still delivering every byte.
                coordinator.processExited(proc.terminationStatus)
                stdoutDrain.finishAfterExit()
                stderrDrain.finishAfterExit()
            }

            try process.run()

            // Close the parent's copy of each pipe's WRITE end now that the child has its own dup.
            // Foundation's `Pipe` keeps the parent-side write handle open; leaving it open makes the
            // parent a permanent writer so the read end never reaches EOF and `read()` blocks
            // forever — the primary headless-CI hang (issue #14). The read ends stay open; the
            // drainers own and close them on teardown.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            return (process, (stdoutDrain, stderrDrain))
        }
    }

    /// Reports whether a `Process.run()` error is a transient fd-table race worth one retry.
    ///
    /// - Parameter error: The error thrown by `Process.run()`.
    /// - Returns: `true` for a POSIX `EBADF` ("Bad file descriptor"); `false` otherwise.
    private static func isTransientSpawnError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EBADF)
    }

    /// Sets `FD_CLOEXEC` on both ends of a pipe so neither end leaks into an unrelated child.
    ///
    /// A concurrently-spawning sibling process must not inherit our pipe fds; an inherited *write*
    /// end keeps the pipe open past our child's exit and stalls EOF on the read end. Foundation
    /// passes the write end to *our* child via `dup2`, which produces a fresh fd without
    /// `FD_CLOEXEC`, so the intended child is unaffected.
    ///
    /// - Parameter pipe: The pipe whose read and write fds should be marked close-on-exec.
    private static func setCloseOnExec(_ pipe: Pipe) {
        for fd in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
            let flags = fcntl(fd, F_GETFD)
            if flags >= 0 {
                _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
            }
        }
    }

    /// A minimal default environment used when ``PaneSpec/environment`` is empty.
    private static func defaultEnvironment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
        ]
    }
}
