import Testing
import Foundation
import RegattaGitHub
@testable import RegattaFleet

@Suite("GitPushActionExecutor — gate-routed real push")
struct GitPushActionExecutorTests {
    private let pr = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 30)

    /// Records every push so a test can assert the worktree + branch a push ran
    /// against.
    private final class RecordingPusher: WorktreePushing, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var pushes: [(URL, String)] = []
        private let error: (any Error)?
        init(error: (any Error)? = nil) { self.error = error }
        func push(worktreePath: URL, branch: String) async throws {
            lock.withLock { pushes.append((worktreePath, branch)) }
            if let error { throw error }
        }
    }

    /// Records non-push actions delegated to the fallback.
    private final class RecordingFallback: ActionExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var executed: [PendingAction] = []
        func execute(_ action: PendingAction) async throws {
            lock.withLock { executed.append(action) }
        }
    }

    private func pushAction(branch: String = "fix-branch") -> PendingAction {
        PendingAction(
            pullRequest: pr,
            kind: .push,
            summary: "Push ci-fix commits to \(branch)",
            payload: ActionPayload(fields: ["branch": branch])
        )
    }

    @Test("a push action runs git push from the resolved worktree to the PR branch")
    func pushRunsGitPushFromWorktree() async throws {
        let worktree = URL(fileURLWithPath: "/tmp/worktrees/ci-fix-30")
        let pusher = RecordingPusher()
        let executor = GitPushActionExecutor(
            resolveWorktree: { _ in worktree },
            pusher: pusher
        )

        try await executor.execute(pushAction(branch: "feature/fix-ci"))

        #expect(pusher.pushes.count == 1)
        #expect(pusher.pushes.first?.0 == worktree)
        #expect(pusher.pushes.first?.1 == "feature/fix-ci")
    }

    @Test("a push with no resolvable worktree throws and does not push")
    func noWorktreeThrows() async {
        let pusher = RecordingPusher()
        let executor = GitPushActionExecutor(
            resolveWorktree: { _ in nil },
            pusher: pusher
        )

        await #expect(throws: GitPushActionError.noWorktree) {
            try await executor.execute(pushAction())
        }
        #expect(pusher.pushes.isEmpty)
    }

    @Test("a push with no branch payload throws missingBranch")
    func missingBranchThrows() async {
        let pusher = RecordingPusher()
        let executor = GitPushActionExecutor(
            resolveWorktree: { _ in URL(fileURLWithPath: "/tmp/wt") },
            pusher: pusher
        )
        let noBranch = PendingAction(pullRequest: pr, kind: .push, summary: "push")

        await #expect(throws: GitPushActionError.missingBranch) {
            try await executor.execute(noBranch)
        }
        #expect(pusher.pushes.isEmpty)
    }

    @Test("non-push actions are delegated to the fallback, not pushed")
    func nonPushDelegatesToFallback() async throws {
        let pusher = RecordingPusher()
        let fallback = RecordingFallback()
        let executor = GitPushActionExecutor(
            resolveWorktree: { _ in URL(fileURLWithPath: "/tmp/wt") },
            pusher: pusher,
            fallback: fallback
        )
        let reply = PendingAction(
            pullRequest: pr,
            kind: .reply,
            summary: "reply",
            payload: ActionPayload(fields: ["body": "hi"])
        )

        try await executor.execute(reply)

        #expect(pusher.pushes.isEmpty)
        #expect(fallback.executed.count == 1)
        #expect(fallback.executed.first?.kind == .reply)
    }
}
