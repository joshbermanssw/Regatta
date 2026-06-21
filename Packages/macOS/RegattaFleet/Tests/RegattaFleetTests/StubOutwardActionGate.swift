import Foundation
@testable import RegattaFleet

/// A deterministic ``OutwardActionGate`` stub for CI-fix-reactor tests.
///
/// Records every ``OutwardAction`` it is asked to authorize and answers with a
/// fixed verdict, so a test can assert that pushes are routed through the gate
/// and exercise both the allowed and denied paths.
final class StubOutwardActionGate: OutwardActionGate, @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [OutwardAction] = []
    private let verdict: OutwardActionVerdict

    /// - Parameter verdict: The verdict returned for every authorize call.
    init(verdict: OutwardActionVerdict = .allowed) {
        self.verdict = verdict
    }

    /// Every action passed to ``authorize(_:)``, in order.
    var requested: [OutwardAction] { lock.withLock { _requested } }

    /// Number of authorize calls.
    var requestCount: Int { lock.withLock { _requested.count } }

    func authorize(_ action: OutwardAction, for pullRequest: PullRequestRef) async -> OutwardActionVerdict {
        lock.withLock { _requested.append(action) }
        return verdict
    }
}
