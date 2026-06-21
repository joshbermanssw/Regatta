import Foundation
import Testing

/// A bounded-wait helper for async tests: races an operation against a deadline so a hang becomes
/// a fast, debuggable test failure instead of a 15-minute CI timeout.
///
/// The headless-CI hang behind issue #14 surfaced as *no output for 15 minutes* — the whole
/// `swiftpm-testing` runner wedged on an `AsyncStream` that never finished, with nothing to point
/// at the offending test. Wrapping every `await` that could block on stream completion or process
/// termination in ``run(seconds:_:)`` converts that class of failure into a sub-second
/// ``TestTimeoutError`` naming the operation, so a regression can never burn the CI budget again.
struct TestTimeout {
    /// Runs `operation`, failing with ``TestTimeoutError`` if it does not finish within `seconds`.
    ///
    /// The operation and a sleeping timer race in a `TaskGroup`; whichever finishes first wins and
    /// the loser is cancelled. The operation must be cancellation-cooperative for the timer to win
    /// promptly, but even an uncooperative operation can no longer hang the *suite* indefinitely:
    /// the timer task returns and the call site throws.
    ///
    /// - Parameters:
    ///   - seconds: The deadline in seconds. Defaults to a value generous enough for honest
    ///     subprocess spawns yet far below any CI step timeout.
    ///   - label: A human-readable name for the operation, surfaced in the thrown error.
    ///   - operation: The async work to bound.
    /// - Returns: The operation's result.
    /// - Throws: ``TestTimeoutError`` if the deadline elapses first; rethrows the operation's error.
    @discardableResult
    static func run<T: Sendable>(
        seconds: Double = 10,
        _ label: String = "operation",
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TestTimeoutError(label: label, seconds: seconds)
            }
            // The first task to finish (the real work or the deadline) wins; cancel the other.
            guard let result = try await group.next() else {
                throw TestTimeoutError(label: label, seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }
}

/// Thrown by ``TestTimeout/run(seconds:_:_:)`` when the bounded operation exceeds its deadline.
struct TestTimeoutError: Error, CustomStringConvertible {
    /// The operation label supplied at the call site.
    let label: String
    /// The deadline, in seconds, that was exceeded.
    let seconds: Double

    var description: String {
        "TestTimeout: \(label) did not complete within \(seconds)s (likely a hung stream/termination)"
    }
}
