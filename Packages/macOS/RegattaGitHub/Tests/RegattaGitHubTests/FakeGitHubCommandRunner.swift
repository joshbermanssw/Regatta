import os
@testable import RegattaGitHub

/// A fake ``GitHubCommandRunning`` for use in unit tests.
///
/// Pre-loads canned responses returned in order. Inject this into
/// ``GitHubPoller`` to test parsing and polling logic without spawning any real
/// process or hitting the network.
///
/// ```swift
/// let fake = FakeGitHubCommandRunner(
///     responses: [.success(checksJSON), .success(reviewThreadsJSON)]
/// )
/// let poller = GitHubPoller(commandRunner: fake)
/// ```
final class FakeGitHubCommandRunner: GitHubCommandRunning, @unchecked Sendable {
    /// Canned responses to return in order.
    enum Response {
        /// Return this JSON string as if `gh` succeeded.
        case success(String)
        /// Throw this error as if `gh` failed.
        case failure(GitHubCommandError)
    }

    private let lock = OSAllocatedUnfairLock(initialState: [Response]())

    init(responses: [Response]) {
        lock.withLock { $0 = responses }
    }

    func run(_ args: [String]) async throws -> String {
        let response = lock.withLock { state -> Response? in
            guard !state.isEmpty else { return nil }
            return state.removeFirst()
        }
        guard let response else {
            throw GitHubCommandError.nonZeroExit(exitStatus: 1, stderr: "FakeGitHubCommandRunner: no more responses")
        }
        switch response {
        case .success(let output):
            return output
        case .failure(let error):
            throw error
        }
    }
}
