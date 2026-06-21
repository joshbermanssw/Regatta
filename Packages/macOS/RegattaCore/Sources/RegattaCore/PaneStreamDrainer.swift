import Foundation

/// Drains a pipe file descriptor incrementally, delivering UTF-8 chunks until end-of-file.
///
/// Wraps `DispatchSource.makeReadSource` — the sanctioned low-level primitive for streaming pipe
/// I/O (cmux-architecture carve-out, since Foundation has no async-native incremental pipe read).
/// The source is confined entirely behind this type; ``ProcessPaneBridge`` exposes only the
/// resulting `AsyncStream` of ``PaneOutputEvent``.
///
/// The drainer owns the read end of the pipe: it reads non-blockingly on its own serial queue,
/// forwards each chunk, and when the write end closes (the child exits) the read returns `0`,
/// triggering ``onEOF`` exactly once and cancelling the source. The fd is closed in the source's
/// cancel handler, so there is no race between closing and an in-flight read. ``cancel()`` forces
/// early teardown (used when the bridge kills the process or the process exits).
///
/// ## Lifecycle safety
/// A `DispatchSource` is created **suspended** and traps in `_dispatch_queue_xref_dispose`
/// (SIGTRAP) if its last reference is released while still suspended. The drainer therefore
/// guarantees the source is **always resumed exactly once** (so it is never freed suspended) and
/// **cancelled exactly once** (so the fd is closed and ``onEOF`` fires) before deallocation:
/// - ``resume()`` resumes the source the first time it is called.
/// - ``deinit`` resumes a never-resumed source and cancels an un-cancelled one, so a drainer
///   dropped on any path (spawn failure, fast exit, killed pane) tears down cleanly. This closes
///   the SIGTRAP crash seen under parallel headless tests on issue #14.
///
/// All `DispatchSource`/flag access happens on the serial `queue`; `deinit` runs only when the last
/// external reference drops, and no handler captures `self` strongly, so `deinit` never races a
/// queue block.
final class PaneStreamDrainer: @unchecked Sendable {
    // Approved DispatchSource carve-out per cmux-architecture. All state below is touched only on
    // `queue`, except in `deinit` which (by definition of deallocation) has exclusive access.
    //
    // The drainer **retains the read `FileHandle`** for the whole pane lifetime. This is the single
    // owner of the read fd: the bridge can let the originating `Pipe` deallocate immediately after
    // spawn without the read fd being yanked out from under us. Critically, `FileHandle` closes its
    // fd on its own deinit, so we must NOT also `close()` the raw fd in the cancel handler — a
    // double-close races fd reuse and shows up as EBADF, SIGPIPE-killed children (exit 13), and lost
    // output under concurrent spawns. We instead close exactly once, via the handle, in the cancel
    // handler.
    private let readHandle: FileHandle
    private let fileDescriptor: Int32
    private let onChunk: @Sendable (String) -> Void
    private let onEOF: @Sendable () -> Void
    private let queue: DispatchQueue
    private let source: any DispatchSourceRead
    private var resumed = false
    private var cancelled = false

    /// Creates a drainer for a readable pipe handle.
    ///
    /// - Parameters:
    ///   - readHandle: The pipe's read-end `FileHandle`. The drainer retains it as the sole owner of
    ///     the underlying fd and closes it exactly once on teardown.
    ///   - onChunk: Invoked with each decoded UTF-8 chunk, on a private serial queue.
    ///   - onEOF: Invoked exactly once when the stream reaches end-of-file or is cancelled.
    init(
        readHandle: FileHandle,
        onChunk: @escaping @Sendable (String) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        self.readHandle = readHandle
        self.fileDescriptor = readHandle.fileDescriptor
        self.onChunk = onChunk
        self.onEOF = onEOF
        self.queue = DispatchQueue(label: "regatta.pane.drain.\(readHandle.fileDescriptor)")

        // Make the read end non-blocking. `read()` is called both from the source's event handler
        // and from the teardown flush; if the fd were blocking and a *stray* copy of the write end
        // were still open (a sibling's inherited fd that lost the CLOEXEC race), a `read()` with no
        // data available would block forever — wedging the drainer's serial queue and, through the
        // `queue.sync` in `resume()`, the bridge actor itself. `O_NONBLOCK` turns that into `EAGAIN`,
        // so a missing EOF can never block; completion is then driven by the process-exit signal.
        let existingFlags = fcntl(fileDescriptor, F_GETFL)
        if existingFlags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, existingFlags | O_NONBLOCK)
        }

        self.source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)

        let handle = readHandle
        let eof = onEOF
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler {
            // Close via the handle — the single fd owner — exactly once. Never `close(fd)` directly:
            // that would double-close once `FileHandle.deinit` also closes, racing fd reuse.
            try? handle.close()
            eof()
        }
    }

    /// Guarantees the source is resumed and cancelled before it is freed, avoiding the
    /// release-while-suspended trap. `deinit` has exclusive access, so no queue hop is needed.
    deinit {
        if !resumed {
            // Never started (e.g. spawn failed before `resume()`). Resume so the source is not freed
            // suspended; the cancel below ensures the handler runs and closes the fd.
            resumed = true
            source.resume()
        }
        if !cancelled {
            cancelled = true
            source.cancel()
        }
    }

    /// Begins delivering chunks. Idempotent; safe to call after teardown (no-op once cancelled).
    func resume() {
        queue.sync {
            guard !resumed, !cancelled else { return }
            resumed = true
            source.resume()
        }
    }

    /// Forces teardown: drains any buffered bytes, then cancels the source (closing the fd and
    /// firing ``onEOF`` once). Safe to call repeatedly and from any thread.
    func cancel() {
        queue.async { [weak self] in
            self?.tearDownLocked()
        }
    }

    /// Completes the drainer once the process has exited, without dropping output.
    ///
    /// Called from the `Process` termination handler. The child is gone, so everything it ever wrote
    /// is already in the pipe buffer; this enqueues — *after* any pending read event already on the
    /// serial queue — a final non-blocking drain that reads all of it, then tears down. Unlike
    /// waiting purely on natural EOF, this also completes when a stray inherited write-end would
    /// otherwise hold the pipe open forever; unlike cancelling immediately, the post-pending-reads
    /// ordering plus the final drain guarantee no trailing byte is lost.
    func finishAfterExit() {
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            if !self.resumed {
                self.resumed = true
                self.source.resume()
            }
            self.tearDownLocked()
        }
    }

    /// Reads whatever is available; on EOF (`read` returns 0) tears down once. Runs on `queue`.
    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBytes { raw in
            read(fileDescriptor, raw.baseAddress, raw.count)
        }
        if count > 0 {
            let data = Data(buffer[0..<count])
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                onChunk(text)
            }
            return
        }
        if count == 0 {
            // EOF: the write end closed (child exited).
            tearDownLocked()
            return
        }
        // count < 0: EAGAIN means try again later; any other error means tear down.
        if errno != EAGAIN && errno != EINTR {
            tearDownLocked()
        }
    }

    /// Cancels the source exactly once, after flushing buffered bytes. Must be called on `queue`.
    ///
    /// `ProcessPaneBridge` cancels the drainers as soon as the process exits (rather than waiting
    /// on natural pipe EOF, which a stray inherited write-end could delay forever). That cancel can
    /// win the queue ahead of the read event handler, so flush synchronously here to guarantee
    /// trailing output reaches the stream before `.terminated`. The source must be resumed before
    /// `cancel()` for the cancel handler (which closes the fd and fires ``onEOF``) to run.
    private func tearDownLocked() {
        guard !cancelled else { return }
        flushRemainingLocked()
        if !resumed {
            resumed = true
            source.resume()
        }
        cancelled = true
        source.cancel()
    }

    /// Reads and forwards every byte currently buffered on the fd. Must be called on `queue`.
    private func flushRemainingLocked() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fileDescriptor, raw.baseAddress, raw.count)
            }
            guard count > 0 else { break }
            let data = Data(buffer[0..<count])
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                onChunk(text)
            }
        }
    }
}
