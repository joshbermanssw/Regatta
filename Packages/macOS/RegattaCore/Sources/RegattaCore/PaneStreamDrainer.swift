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
/// early teardown (used when the bridge kills the process).
final class PaneStreamDrainer: @unchecked Sendable {
    // All fd access happens on `queue` (the DispatchSource's queue); `eofFired` is a one-shot flag
    // touched only there. Approved DispatchSource carve-out per cmux-architecture.
    private let fileDescriptor: Int32
    private let onChunk: @Sendable (String) -> Void
    private let onEOF: @Sendable () -> Void
    private let queue: DispatchQueue
    private let source: any DispatchSourceRead
    private var eofFired = false

    /// Creates a drainer for a readable file descriptor.
    ///
    /// - Parameters:
    ///   - fileDescriptor: The pipe's read end. Ownership transfers to the drainer, which closes
    ///     it when the source is cancelled.
    ///   - onChunk: Invoked with each decoded UTF-8 chunk, on a private serial queue.
    ///   - onEOF: Invoked exactly once when the stream reaches end-of-file or is cancelled.
    init(
        fileDescriptor: Int32,
        onChunk: @escaping @Sendable (String) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        self.fileDescriptor = fileDescriptor
        self.onChunk = onChunk
        self.onEOF = onEOF
        self.queue = DispatchQueue(label: "regatta.pane.drain.\(fileDescriptor)")
        self.source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)

        let fd = fileDescriptor
        let eof = onEOF
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler {
            close(fd)
            eof()
        }
    }

    /// Begins delivering chunks.
    func resume() {
        source.resume()
    }

    /// Forces teardown: cancels the source, which closes the fd and fires ``onEOF`` once.
    func cancel() {
        queue.async { [weak self] in
            self?.fireEOFAndCancel()
        }
    }

    /// Reads whatever is available; on EOF (`read` returns 0) tears down once.
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
            fireEOFAndCancel()
            return
        }
        // count < 0: EAGAIN means try again later; any other error means tear down.
        if errno != EAGAIN && errno != EINTR {
            fireEOFAndCancel()
        }
    }

    /// Cancels the source exactly once. The cancel handler closes the fd and fires ``onEOF``.
    private func fireEOFAndCancel() {
        guard !eofFired else { return }
        eofFired = true
        source.cancel()
    }
}
