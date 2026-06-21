import Foundation

/// Coordinates the three signals that must all arrive before a pane's stream is finished.
///
/// A pane finishes only once **all** of: stdout reached EOF, stderr reached EOF, and the process
/// reported its exit code. Waiting for both pipe EOFs before emitting
/// ``PaneOutputEvent/terminated(_:)`` guarantees every byte the agent wrote is delivered as a
/// ``PaneOutputEvent/stdout(_:)`` / ``PaneOutputEvent/stderr(_:)`` event *before* the terminal
/// event — downstream condition checks never miss trailing output.
///
/// This is the lock carve-out from cmux-architecture: a synchronous compare-and-set over three
/// tiny flags, called from non-async callbacks (two `DispatchSource` cancel handlers and the
/// `Process` termination handler). Promoting it to an actor would only add `Task`/`await` hops.
final class PaneTerminationCoordinator: @unchecked Sendable {
    // NSLock guards three one-shot flags + the exit code — not ongoing domain state.
    // Approved carve-out per cmux-architecture.
    private let lock = NSLock()
    private var stdoutDone = false
    private var stderrDone = false
    private var exitCode: Int32?
    private var emitted = false
    private let onComplete: @Sendable (Int32) -> Void

    /// Creates a coordinator that calls `onComplete` exactly once when all signals have arrived.
    ///
    /// - Parameter onComplete: Invoked with the process exit code after stdout EOF, stderr EOF,
    ///   and process exit have all occurred.
    init(onComplete: @escaping @Sendable (Int32) -> Void) {
        self.onComplete = onComplete
    }

    /// Records that stdout reached end-of-file.
    func stdoutFinished() {
        lock.lock(); stdoutDone = true; lock.unlock()
        completeIfReady()
    }

    /// Records that stderr reached end-of-file.
    func stderrFinished() {
        lock.lock(); stderrDone = true; lock.unlock()
        completeIfReady()
    }

    /// Records the process exit code.
    ///
    /// - Parameter code: The process exit/termination status.
    func processExited(_ code: Int32) {
        lock.lock(); exitCode = code; lock.unlock()
        completeIfReady()
    }

    /// Completes immediately with `code`, without waiting for pipe EOFs.
    ///
    /// Used only by a forced ``ProcessPaneBridge/terminate(_:)``: a killed agent may leave a
    /// grandchild holding the pipe write end open, so EOF could be delayed indefinitely. The
    /// drainers are cancelled in parallel to release the read fds, but stream completion does not
    /// depend on their async EOF callbacks arriving. Fires `onComplete` exactly once; a later
    /// natural-exit or EOF signal is a no-op.
    ///
    /// - Parameter code: The terminal status to report.
    func forceComplete(_ code: Int32) {
        lock.lock()
        guard !emitted else {
            lock.unlock()
            return
        }
        emitted = true
        lock.unlock()
        onComplete(code)
    }

    /// Fires `onComplete` once, only after all three signals have been recorded.
    private func completeIfReady() {
        lock.lock()
        guard stdoutDone, stderrDone, let code = exitCode, !emitted else {
            lock.unlock()
            return
        }
        emitted = true
        lock.unlock()
        onComplete(code)
    }
}
