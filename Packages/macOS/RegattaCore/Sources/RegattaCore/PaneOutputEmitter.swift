import Foundation

/// Owns a ``PaneOutputEvent`` `AsyncStream` continuation and guarantees a single terminal event.
///
/// Output chunks and the one terminal ``PaneOutputEvent/terminated(_:)`` event arrive from
/// several synchronous callbacks (two `DispatchSource` handlers and a `Process` termination
/// handler). This box guards a one-shot `finished` flag with a lock so the stream is finished
/// exactly once and no event is yielded after finish.
///
/// This is the lock carve-out from cmux-architecture: a synchronous compare-and-set over a tiny
/// flag, called from non-async callbacks. Promoting it to an actor would only add `Task`/`await`
/// hops to a one-shot guard.
final class PaneOutputEmitter: @unchecked Sendable {
    // NSLock guards a one-shot Bool + the continuation/awaiters — not ongoing domain state.
    // Approved carve-out per cmux-architecture.
    private let lock = NSLock()
    private var continuation: AsyncStream<PaneOutputEvent>.Continuation?
    private var finished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    /// Stores the stream continuation produced by the `AsyncStream` initializer.
    ///
    /// - Parameter continuation: The continuation to feed events into.
    func attach(_ continuation: AsyncStream<PaneOutputEvent>.Continuation) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.finish()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Yields an output event if the stream is still open; a no-op once finished.
    ///
    /// - Parameter event: The event to deliver.
    func yield(_ event: PaneOutputEvent) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        lock.unlock()
        continuation.yield(event)
    }

    /// Emits the terminal ``PaneOutputEvent/terminated(_:)`` exactly once and finishes the stream.
    ///
    /// - Parameter code: The process exit/termination status.
    func finish(code: Int32) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let waiters = finishWaiters
        finishWaiters = []
        lock.unlock()

        continuation?.yield(.terminated(code))
        continuation?.finish()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Suspends until the stream has finished (the terminal event was emitted).
    func waitUntilFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                finishWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
