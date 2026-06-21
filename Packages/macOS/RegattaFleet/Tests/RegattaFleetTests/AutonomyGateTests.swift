import Testing
import Foundation
import RegattaGitHub
@testable import RegattaFleet

@Suite("AutonomyGate — staged vs auto gating")
struct AutonomyGateTests {
    private let pr = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 28)
    private let other = PullRequestRef(owner: "manaflow-ai", repo: "cmux", number: 99)

    private func action(
        _ kind: ActionKind,
        pr: PullRequestRef,
        summary: String = "do thing"
    ) -> PendingAction {
        PendingAction(pullRequest: pr, kind: kind, summary: summary)
    }

    // MARK: - Default mode

    @Test("a PR with no explicit mode defaults to staged")
    func defaultsToStaged() async {
        let gate = AutonomyGate(executor: RecordingActionExecutor())
        #expect(await gate.mode(for: pr) == .staged)
    }

    // MARK: - Staged enqueues, does not execute

    @Test("in staged mode submit enqueues and does not execute")
    func stagedEnqueues() async {
        let exec = RecordingActionExecutor()
        let gate = AutonomyGate(executor: exec)

        let result = await gate.submit(action(.push, pr: pr))

        if case .enqueued(let a) = result {
            #expect(a.kind == .push)
        } else {
            Issue.record("expected .enqueued, got \(result)")
        }
        #expect(exec.executeCount == 0)
        let queue = await gate.currentPending()
        #expect(queue.count == 1)
        #expect(queue.first?.status == .pending)
    }

    // MARK: - Auto executes immediately

    @Test("in auto mode submit executes immediately and does not enqueue")
    func autoExecutes() async {
        let exec = RecordingActionExecutor()
        let gate = AutonomyGate(executor: exec)
        await gate.setMode(.auto, for: pr)

        let result = await gate.submit(action(.resolve, pr: pr))

        if case .executed(let a) = result {
            #expect(a.status == .completed)
        } else {
            Issue.record("expected .executed, got \(result)")
        }
        #expect(exec.executeCount == 1)
        #expect(await gate.currentPending().isEmpty)
    }

    @Test("auto mode reports executionFailed when the executor throws")
    func autoExecutionFailed() async {
        let exec = RecordingActionExecutor(shouldThrow: true)
        let gate = AutonomyGate(executor: exec)
        await gate.setMode(.auto, for: pr)

        let result = await gate.submit(action(.push, pr: pr))

        if case .executionFailed(let a) = result {
            #expect(a.status == .failed)
        } else {
            Issue.record("expected .executionFailed, got \(result)")
        }
        #expect(exec.executeCount == 0)
    }

    // MARK: - Approve

    @Test("approving a pending action executes it and removes it from the queue")
    func approveExecutes() async {
        let exec = RecordingActionExecutor()
        let gate = AutonomyGate(executor: exec)

        let submitted = action(.reply, pr: pr)
        await gate.submit(submitted)
        #expect(exec.executeCount == 0)

        let resolved = await gate.approve(submitted.id)
        #expect(resolved?.status == .completed)
        #expect(exec.executeCount == 1)
        #expect(exec.executed.first?.id == submitted.id)
        #expect(await gate.currentPending().isEmpty)
    }

    @Test("approving a failing action marks it failed and still clears the queue")
    func approveFailure() async {
        let exec = RecordingActionExecutor(shouldThrow: true)
        let gate = AutonomyGate(executor: exec)

        let submitted = action(.push, pr: pr)
        await gate.submit(submitted)

        let resolved = await gate.approve(submitted.id)
        #expect(resolved?.status == .failed)
        #expect(await gate.currentPending().isEmpty)
    }

    @Test("approving an unknown id returns nil and executes nothing")
    func approveUnknown() async {
        let exec = RecordingActionExecutor()
        let gate = AutonomyGate(executor: exec)
        let resolved = await gate.approve(UUID())
        #expect(resolved == nil)
        #expect(exec.executeCount == 0)
    }

    // MARK: - Reject

    @Test("rejecting a pending action drops it without executing")
    func rejectDrops() async {
        let exec = RecordingActionExecutor()
        let gate = AutonomyGate(executor: exec)

        let submitted = action(.resolve, pr: pr)
        await gate.submit(submitted)

        let rejected = await gate.reject(submitted.id)
        #expect(rejected?.status == .rejected)
        #expect(exec.executeCount == 0)
        #expect(await gate.currentPending().isEmpty)
    }

    @Test("rejecting an unknown id returns nil")
    func rejectUnknown() async {
        let gate = AutonomyGate(executor: RecordingActionExecutor())
        #expect(await gate.reject(UUID()) == nil)
    }

    // MARK: - Per-PR isolation

    @Test("autonomy mode is per-PR and isolated")
    func perPRIsolation() async {
        let exec = RecordingActionExecutor()
        let gate = AutonomyGate(executor: exec)

        // Flip only `pr` to auto; `other` stays staged (default).
        await gate.setMode(.auto, for: pr)
        #expect(await gate.mode(for: pr) == .auto)
        #expect(await gate.mode(for: other) == .staged)

        await gate.submit(action(.push, pr: pr))      // auto → executes
        await gate.submit(action(.push, pr: other))   // staged → enqueues

        #expect(exec.executeCount == 1)
        let queue = await gate.currentPending()
        #expect(queue.count == 1)
        #expect(queue.first?.pullRequest.id == other.id)
        #expect(await gate.currentPending(for: pr).isEmpty)
        #expect(await gate.currentPending(for: other).count == 1)
    }

    @Test("flipping a PR to auto does not auto-drain its already-pending actions")
    func flippingToAutoLeavesPendingForApproval() async {
        let exec = RecordingActionExecutor()
        let gate = AutonomyGate(executor: exec)

        let staged = action(.push, pr: pr)
        await gate.submit(staged)            // staged → enqueued
        await gate.setMode(.auto, for: pr)   // user flips toggle

        // The already-queued action stays pending until explicitly approved.
        #expect(await gate.currentPending().count == 1)
        #expect(exec.executeCount == 0)

        // New submissions now auto-execute.
        await gate.submit(action(.reply, pr: pr))
        #expect(exec.executeCount == 1)
        #expect(await gate.currentPending().count == 1) // the original still pending
    }

    // MARK: - Stream

    @Test("pendingActions stream replays current queue then emits on change")
    func streamReplaysAndEmits() async {
        let gate = AutonomyGate(executor: RecordingActionExecutor())
        let submitted = action(.push, pr: pr)
        await gate.submit(submitted)

        let stream = await gate.pendingActions()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.count == 1)

        await gate.reject(submitted.id)
        let second = await iterator.next()
        #expect(second?.isEmpty == true)
    }
}
