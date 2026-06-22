import Foundation
import RegattaGitHub

/// A ``PullRequestPolling`` fake that returns a *scripted sequence* of check
/// results across successive ``fetchChecks`` calls.
///
/// The CI fix loop re-polls each iteration, so a test needs the poll to change
/// over time — red, red, then green. This fake pops the next scripted result per
/// call and repeats the final entry once the script is exhausted. Optionally a
/// scripted entry can be an error to exercise the transient-failure path.
final class SequencedPullRequestPoller: PullRequestPolling, @unchecked Sendable {
    /// One scripted poll result: either checks or a thrown error.
    enum Step: Sendable {
        case checks([PRCheck])
        case failure(GitHubCommandError)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var index = 0
    private var _calls = 0

    init(_ steps: [Step]) {
        precondition(!steps.isEmpty, "script must have at least one step")
        self.steps = steps
    }

    /// Number of ``fetchChecks`` calls made.
    var calls: Int { lock.withLock { _calls } }

    func fetchChecks(owner: String, repo: String, prNumber: Int) async throws -> [PRCheck] {
        let step: Step = lock.withLock {
            _calls += 1
            let s = steps[min(index, steps.count - 1)]
            if index < steps.count - 1 { index += 1 }
            return s
        }
        switch step {
        case .checks(let checks):
            return checks
        case .failure(let error):
            throw error
        }
    }

    func fetchReviewThreads(owner: String, repo: String, prNumber: Int) async throws -> [ReviewThread] {
        []
    }

    func fetchConversationComments(owner: String, repo: String, prNumber: Int) async throws -> [PRConversationComment] {
        []
    }

    func currentUserLogin() async throws -> String {
        "shepherd-bot"
    }
}
