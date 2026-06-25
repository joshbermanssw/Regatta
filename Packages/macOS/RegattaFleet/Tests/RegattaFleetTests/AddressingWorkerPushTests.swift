import Testing
import Foundation
import RegattaGitHub
@testable import RegattaFleet

/// Behavior-level tests for the **addressing reactors' push path** (C1).
///
/// The three addressing workers (review thread, conversation comment, review
/// summary) must mirror the ci-fix push design: resolve the PR's head branch,
/// route the push through the gate **carrying that branch**, and DECLINE (report
/// not-fully-handled, surfacing needs-attention) when the head branch is
/// unresolved rather than pushing to a junk branch.
///
/// Before this fix the push carried no branch, so routed through the production
/// ``GitPushActionExecutor`` it threw ``GitPushActionError/missingBranch`` →
/// `.denied` → never handled → re-spawned every poll forever.
@Suite("Addressing workers — gate-routed push carries the head branch (C1)")
struct AddressingWorkerPushTests {
    private let pr = PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: 9)

    /// Records pushes the production executor runs.
    private final class RecordingPusher: WorktreePushing, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var pushes: [(URL, String)] = []
        func push(worktreePath: URL, branch: String) async throws {
            lock.withLock { pushes.append((worktreePath, branch)) }
        }
    }

    /// A spawner whose addressing surfaces report a pushed change and record a
    /// fixed worktree into the given store (mirroring the real spawner).
    private final class PushingSpawner: WorkerSpawning, @unchecked Sendable {
        let worktree: URL
        let store: CIFixWorktreeStore
        init(worktree: URL, store: CIFixWorktreeStore) {
            self.worktree = worktree
            self.store = store
        }
        func spawn(_ spec: CIFixWorkerSpec) async -> any CIFixWorkerHandle {
            fatalError("ci-fix path not exercised")
        }
        func spawnWorker(for request: ReviewThreadWorkRequest) async throws -> ReviewThreadWorkResult {
            await store.record(worktree, for: request.pullRequest)
            return ReviewThreadWorkResult(pushedCodeChange: true, replyBody: nil, shouldResolve: false)
        }
        func spawnWorker(for request: ConversationCommentWorkRequest) async throws -> ConversationCommentWorkResult {
            await store.record(worktree, for: request.pullRequest)
            return ConversationCommentWorkResult(pushedCodeChange: true, replyBody: nil)
        }
        func spawnWorker(for request: ReviewSummaryWorkRequest) async throws -> ReviewSummaryWorkResult {
            await store.record(worktree, for: request.pullRequest)
            return ReviewSummaryWorkResult(pushedCodeChange: true, replyBody: nil)
        }
    }

    private func makeProductionGate(store: CIFixWorktreeStore, pusher: RecordingPusher) -> AutonomyGate {
        let executor = GitPushActionExecutor(
            resolveWorktree: { action in await store.worktree(for: action.pullRequest) },
            pusher: pusher
        )
        return AutonomyGate(executor: executor, defaultMode: .auto)
    }

    // MARK: - Review thread

    @Test("review-thread push targets the resolved head branch and marks handled")
    func reviewThreadPushTargetsBranch() async {
        let worktree = URL(fileURLWithPath: "/tmp/wt/thread")
        let store = CIFixWorktreeStore()
        let pusher = RecordingPusher()
        let gate = makeProductionGate(store: store, pusher: pusher)
        let spawner = PushingSpawner(worktree: worktree, store: store)
        let worker = ReviewThreadWorker(
            spawner: spawner, writer: StubPullRequestWriter(), gate: gate,
            log: StubActivityLog(), headBranchResolver: { _ in "feature/x" }
        )

        let handled = await worker.handle(makeThread("T1"), in: pr)

        #expect(handled)
        #expect(pusher.pushes.count == 1)
        #expect(pusher.pushes.first?.0 == worktree)
        #expect(pusher.pushes.first?.1 == "feature/x")
    }

    @Test("review-thread declines the push when the head branch is unresolved")
    func reviewThreadDeclinesWithoutBranch() async {
        let store = CIFixWorktreeStore()
        let pusher = RecordingPusher()
        let gate = makeProductionGate(store: store, pusher: pusher)
        let spawner = PushingSpawner(worktree: URL(fileURLWithPath: "/tmp/wt/thread"), store: store)
        let worker = ReviewThreadWorker(
            spawner: spawner, writer: StubPullRequestWriter(), gate: gate,
            log: StubActivityLog(), headBranchResolver: { _ in nil }
        )

        let handled = await worker.handle(makeThread("T1"), in: pr)

        #expect(!handled, "an unresolved head branch must not push and must leave the thread for retry")
        #expect(pusher.pushes.isEmpty, "must not push to a junk branch")
    }

    // MARK: - Conversation comment

    @Test("conversation-comment push targets the resolved head branch")
    func conversationPushTargetsBranch() async {
        let worktree = URL(fileURLWithPath: "/tmp/wt/conv")
        let store = CIFixWorktreeStore()
        let pusher = RecordingPusher()
        let gate = makeProductionGate(store: store, pusher: pusher)
        let spawner = PushingSpawner(worktree: worktree, store: store)
        let worker = ConversationCommentWorker(
            spawner: spawner, writer: StubPullRequestWriter(), gate: gate,
            log: NoopConversationCommentLog(), headBranchResolver: { _ in "feature/x" }
        )

        let handled = await worker.handle(
            PRConversationComment(id: "C1", body: "fix it", author: "alice", url: "u", createdAt: "t"),
            in: pr
        )

        #expect(handled)
        #expect(pusher.pushes.first?.1 == "feature/x")
    }

    @Test("conversation-comment declines the push when the head branch is unresolved")
    func conversationDeclinesWithoutBranch() async {
        let store = CIFixWorktreeStore()
        let pusher = RecordingPusher()
        let gate = makeProductionGate(store: store, pusher: pusher)
        let spawner = PushingSpawner(worktree: URL(fileURLWithPath: "/tmp/wt/conv"), store: store)
        let worker = ConversationCommentWorker(
            spawner: spawner, writer: StubPullRequestWriter(), gate: gate,
            log: NoopConversationCommentLog(), headBranchResolver: { _ in nil }
        )

        let handled = await worker.handle(
            PRConversationComment(id: "C1", body: "fix it", author: "alice", url: "u", createdAt: "t"),
            in: pr
        )

        #expect(!handled)
        #expect(pusher.pushes.isEmpty)
    }

    // MARK: - Review summary

    @Test("review-summary push targets the resolved head branch")
    func reviewSummaryPushTargetsBranch() async {
        let worktree = URL(fileURLWithPath: "/tmp/wt/review")
        let store = CIFixWorktreeStore()
        let pusher = RecordingPusher()
        let gate = makeProductionGate(store: store, pusher: pusher)
        let spawner = PushingSpawner(worktree: worktree, store: store)
        let worker = ReviewSummaryWorker(
            spawner: spawner, writer: StubPullRequestWriter(), gate: gate,
            log: StubReviewSummaryActivityLog(), headBranchResolver: { _ in "feature/x" }
        )

        let handled = await worker.handle(
            PRReview(id: "R1", author: "alice", state: .changesRequested, body: "please fix", submittedAt: "t"),
            in: pr
        )

        #expect(handled)
        #expect(pusher.pushes.first?.1 == "feature/x")
    }

    @Test("review-summary declines the push when the head branch is unresolved")
    func reviewSummaryDeclinesWithoutBranch() async {
        let store = CIFixWorktreeStore()
        let pusher = RecordingPusher()
        let gate = makeProductionGate(store: store, pusher: pusher)
        let spawner = PushingSpawner(worktree: URL(fileURLWithPath: "/tmp/wt/review"), store: store)
        let worker = ReviewSummaryWorker(
            spawner: spawner, writer: StubPullRequestWriter(), gate: gate,
            log: StubReviewSummaryActivityLog(), headBranchResolver: { _ in nil }
        )

        let handled = await worker.handle(
            PRReview(id: "R1", author: "alice", state: .changesRequested, body: "please fix", submittedAt: "t"),
            in: pr
        )

        #expect(!handled)
        #expect(pusher.pushes.isEmpty)
    }
}
