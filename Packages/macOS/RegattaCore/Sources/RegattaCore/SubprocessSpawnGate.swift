import Foundation

/// Serializes subprocess launches across the whole process so concurrent spawns cannot inherit one
/// another's file descriptors.
///
/// `Process` (via `posix_spawn`) snapshots the entire open-fd table into the new child unless each
/// fd is marked close-on-exec. When two launches race, the window between *creating* one launch's
/// pipe/file fds and *exec'ing* its child can overlap a sibling's `posix_spawn`, so the sibling's
/// child inherits fds it should never see. For a pipe that means an extra copy of the *write* end
/// living in an unrelated process, so the reader never observes EOF and the output stream hangs —
/// the headless-CI failure behind issue #14. It also surfaces as transient `EBADF` ("Bad file
/// descriptor") when the racing launches reuse fd numbers.
///
/// Routing every launch through ``run(_:)`` collapses that window: the fd-table-mutating section
/// (open the pipes/files, then `process.run()`) executes one launch at a time. Because the gate is
/// an `actor`, callers `await` it without blocking a thread, and the body stays synchronous and
/// short. This is the spawn-side complement to marking pipe fds close-on-exec — together they make
/// concurrent subprocess tests deterministic.
///
/// The fd table is a genuinely process-global resource, so the serialization point is process-wide
/// via ``shared``. (`static let` here is a declaration of a single shared coordination actor, not a
/// mutable-state singleton — the only state it owns is the implicit actor mailbox.)
actor SubprocessSpawnGate {
    /// The process-wide spawn gate. Every subprocess launch in this package routes through it.
    static let shared = SubprocessSpawnGate()

    /// Creates a gate. Prefer ``shared``; a fresh instance is useful only in isolated tests.
    init() {}

    /// Runs `body` — the fd-table-mutating launch section — with no other gated launch interleaving.
    ///
    /// Keep `body` to exactly the racy work: create the pipes/file handles for the child, wire them
    /// onto the `Process`, and call `process.run()`. Everything else (draining, waiting for exit)
    /// belongs *outside* the gate so a long-running child never blocks other launches.
    ///
    /// - Parameter body: The launch section to serialize. Declared `sending` so it may capture a
    ///   non-`Sendable` `Process`/`Pipe`; ownership transfers into the gate for the call's duration.
    /// - Returns: Whatever `body` returns, transferred back out via `sending`.
    /// - Throws: Rethrows any error `body` throws (e.g. a failed `process.run()`).
    func run<T>(_ body: sending () throws -> sending T) rethrows -> sending T {
        try body()
    }
}
