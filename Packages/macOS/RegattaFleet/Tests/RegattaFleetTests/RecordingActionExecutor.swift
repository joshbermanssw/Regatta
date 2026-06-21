import Foundation
@testable import RegattaFleet

/// A deterministic ``ActionExecuting`` test double.
///
/// Records every action it executes (in order) and can be told to throw on the
/// next call, so the gate's auto-execute, approve, and failure paths are
/// exercised without any `gh`/network access.
final class RecordingActionExecutor: ActionExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _executed: [PendingAction] = []
    private var _shouldThrow = false

    init(shouldThrow: Bool = false) {
        self._shouldThrow = shouldThrow
    }

    /// The actions that were executed, in execution order.
    var executed: [PendingAction] { lock.withLock { _executed } }

    /// How many actions were executed.
    var executeCount: Int { lock.withLock { _executed.count } }

    /// Toggles whether the next `execute` throws.
    func setShouldThrow(_ value: Bool) {
        lock.withLock { _shouldThrow = value }
    }

    struct ExecutionError: Error {}

    func execute(_ action: PendingAction) async throws {
        try lock.withLock {
            if _shouldThrow { throw ExecutionError() }
            _executed.append(action)
        }
    }
}
