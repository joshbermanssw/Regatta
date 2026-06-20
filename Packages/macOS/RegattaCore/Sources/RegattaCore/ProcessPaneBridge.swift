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

        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.workingDirectory
        process.environment = spec.environment.isEmpty ? Self.defaultEnvironment() : spec.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

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

        // Drain both pipes incrementally. Each drainer owns its read fd and closes it on cancel,
        // then reports EOF to the coordinator. DispatchSource is the sanctioned low-level
        // primitive for streaming pipe I/O (cmux-architecture carve-out), hidden behind the
        // AsyncStream.
        let stdoutDrain = PaneStreamDrainer(
            fileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor,
            onChunk: { emitter.yield(.stdout($0)) },
            onEOF: { coordinator.stdoutFinished() }
        )
        let stderrDrain = PaneStreamDrainer(
            fileDescriptor: stderrPipe.fileHandleForReading.fileDescriptor,
            onChunk: { emitter.yield(.stderr($0)) },
            onEOF: { coordinator.stderrFinished() }
        )

        process.terminationHandler = { proc in
            coordinator.processExited(proc.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            // Spawn failed: nothing will close the pipes, so cancel the drainers (closes fds) and
            // synthesize a terminal event for any consumer already iterating the stream.
            stdoutDrain.cancel()
            stderrDrain.cancel()
            emitter.finish(code: -1)
            throw PaneBridgeError.spawnFailed(String(describing: error))
        }

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

    /// A minimal default environment used when ``PaneSpec/environment`` is empty.
    private static func defaultEnvironment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
        ]
    }
}
