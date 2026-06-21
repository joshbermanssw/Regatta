import Foundation
import RegattaGitHub

/// A deterministic ``PullRequestPolling`` fake for Fleet tests.
///
/// Returns canned checks and review threads, counts how many times it was
/// polled, and can be told to throw a specific ``GitHubCommandError`` to
/// exercise the watcher's failure handling. No process or network is involved.
final class FakePullRequestPoller: PullRequestPolling, @unchecked Sendable {
    private let lock = NSLock()
    private var _checks: [PRCheck]
    private var _threads: [ReviewThread]
    private var _error: GitHubCommandError?
    private var _checkCalls = 0
    private var _threadCalls = 0

    init(
        checks: [PRCheck] = [],
        threads: [ReviewThread] = [],
        error: GitHubCommandError? = nil
    ) {
        self._checks = checks
        self._threads = threads
        self._error = error
    }

    /// Number of times ``fetchChecks`` has been called.
    var checkCalls: Int { lock.withLock { _checkCalls } }
    /// Number of times ``fetchReviewThreads`` has been called.
    var threadCalls: Int { lock.withLock { _threadCalls } }

    /// Replaces the canned responses (e.g. to simulate CI turning green).
    func set(checks: [PRCheck], threads: [ReviewThread], error: GitHubCommandError? = nil) {
        lock.withLock {
            _checks = checks
            _threads = threads
            _error = error
        }
    }

    func fetchChecks(owner: String, repo: String, prNumber: Int) async throws -> [PRCheck] {
        try lock.withLock {
            _checkCalls += 1
            if let error = _error { throw error }
            return _checks
        }
    }

    func fetchReviewThreads(owner: String, repo: String, prNumber: Int) async throws -> [ReviewThread] {
        try lock.withLock {
            _threadCalls += 1
            if let error = _error { throw error }
            return _threads
        }
    }
}
