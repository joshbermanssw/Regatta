import Testing
import Foundation
import RegattaGitHub
@testable import RegattaFleet

/// Tests the ``AutonomyGate`` ⇒ ``OutwardActionGate`` mapping, specifically that
/// **every** push-kind outward action carries a non-empty `branch` in its payload
/// so the production ``GitPushActionExecutor`` can run the real `git push`.
///
/// ## Regression: addressing-reactor pushes had no branch (C1)
/// `pushFix` already carried `branch`, but the three addressing pushes
/// (`pushCodeChange` / `pushConversationChange` / `pushReviewChange`) mapped to a
/// `.push` payload with only thread/comment/review id and **no branch**. Routed
/// through the production gate, the executor threw ``GitPushActionError/missingBranch``,
/// so the verdict was `.denied`, the worker never marked the work handled, and the
/// reactor re-spawned every poll forever. These tests pin the contract that all
/// four push actions carry the PR's head branch.
@Suite("AutonomyGate+OutwardActionGate — every push carries a branch")
struct AutonomyGateOutwardActionMappingTests {
    private let pr = PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: 7)

    /// Captures the ``PendingAction`` the gate submits to the executor, so a test
    /// can assert the kind + payload an outward action maps to.
    private final class CapturingExecutor: ActionExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var actions: [PendingAction] = []
        func execute(_ action: PendingAction) async throws {
            lock.withLock { actions.append(action) }
        }
    }

    private func makeGate() -> (AutonomyGate, CapturingExecutor) {
        let executor = CapturingExecutor()
        // auto mode so submit() runs the executor immediately, letting us inspect
        // the PendingAction it was handed.
        let gate = AutonomyGate(executor: executor, defaultMode: .auto)
        return (gate, executor)
    }

    @Test("pushFix maps to a push carrying the head branch")
    func pushFixCarriesBranch() async {
        let (gate, executor) = makeGate()
        let verdict = await gate.authorize(.pushFix(pullRequest: pr, branch: "feature/x"), for: pr)
        #expect(verdict == .allowed)
        #expect(executor.actions.first?.kind == .push)
        #expect(executor.actions.first?.payload?["branch"] == "feature/x")
    }

    @Test("pushCodeChange (review thread) maps to a push carrying the head branch")
    func pushCodeChangeCarriesBranch() async {
        let (gate, executor) = makeGate()
        let verdict = await gate.authorize(
            .pushCodeChange(threadID: "T1", branch: "feature/x"), for: pr
        )
        #expect(verdict == .allowed)
        let action = executor.actions.first
        #expect(action?.kind == .push)
        #expect(action?.payload?["branch"] == "feature/x")
        #expect(action?.payload?["threadID"] == "T1")
    }

    @Test("pushConversationChange maps to a push carrying the head branch")
    func pushConversationChangeCarriesBranch() async {
        let (gate, executor) = makeGate()
        let verdict = await gate.authorize(
            .pushConversationChange(commentID: "C1", branch: "feature/x"), for: pr
        )
        #expect(verdict == .allowed)
        let action = executor.actions.first
        #expect(action?.kind == .push)
        #expect(action?.payload?["branch"] == "feature/x")
        #expect(action?.payload?["commentID"] == "C1")
    }

    @Test("pushReviewChange maps to a push carrying the head branch")
    func pushReviewChangeCarriesBranch() async {
        let (gate, executor) = makeGate()
        let verdict = await gate.authorize(
            .pushReviewChange(reviewID: "R1", branch: "feature/x"), for: pr
        )
        #expect(verdict == .allowed)
        let action = executor.actions.first
        #expect(action?.kind == .push)
        #expect(action?.payload?["branch"] == "feature/x")
        #expect(action?.payload?["reviewID"] == "R1")
    }

    /// The real production executor (``GitPushActionExecutor``) must accept the
    /// addressing push without throwing ``GitPushActionError/missingBranch`` — the
    /// exact failure that made the reactor re-spawn forever.
    @Test("addressing push through the production executor pushes to the head branch")
    func addressingPushThroughProductionExecutorTargetsBranch() async throws {
        let worktree = URL(fileURLWithPath: "/tmp/worktrees/addressing")
        final class RecordingPusher: WorktreePushing, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var pushes: [(URL, String)] = []
            func push(worktreePath: URL, branch: String) async throws {
                lock.withLock { pushes.append((worktreePath, branch)) }
            }
        }
        let pusher = RecordingPusher()
        let executor = GitPushActionExecutor(
            resolveWorktree: { _ in worktree },
            pusher: pusher
        )
        let gate = AutonomyGate(executor: executor, defaultMode: .auto)

        let verdict = await gate.authorize(
            .pushCodeChange(threadID: "T1", branch: "feature/x"), for: pr
        )

        #expect(verdict == .allowed)
        #expect(pusher.pushes.count == 1)
        #expect(pusher.pushes.first?.1 == "feature/x")
    }
}
