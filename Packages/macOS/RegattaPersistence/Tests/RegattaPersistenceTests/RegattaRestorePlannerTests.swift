import Foundation
import Testing
@testable import RegattaPersistence
import RegattaCore

/// Tests the per-entity restore semantics: workers that were live become
/// ``WorkerStatus/interrupted``, running loops are re-armed to idle while
/// config + history are preserved, and terminal states are untouched.
@Suite struct RegattaRestorePlannerTests {

    private let planner = RegattaRestorePlanner()

    @Test(arguments: [
        WorkerStatus.queued,
        WorkerStatus.running,
    ])
    func liveWorkersRestoreAsInterrupted(_ status: WorkerStatus) {
        #expect(planner.restoredWorkerStatus(from: status) == .interrupted)
    }

    @Test(arguments: [
        WorkerStatus.done,
        WorkerStatus.failed("x"),
        WorkerStatus.blocked("worktree conflict"),
        WorkerStatus.cancelled,
        WorkerStatus.interrupted,
    ])
    func nonLiveWorkersKeepStatus(_ status: WorkerStatus) {
        #expect(planner.restoredWorkerStatus(from: status) == status)
    }

    /// A #35 `blocked` worker is a human-resolution state and is preserved
    /// verbatim on restore (not coerced to `interrupted`), so its reason and
    /// banner reappear after a restart.
    @Test func blockedWorkerKeepsStatusWithReason() {
        let restored = planner.restoredWorkerStatus(from: .blocked("merge conflict"))
        #expect(restored == .blocked("merge conflict"))
    }

    @Test func restoredWorkersAppliesRuleAcrossSnapshot() {
        let running = WorkerSnapshot(id: UUID(), name: "a", prompt: "p", status: .running, providerID: .claudeCode)
        let done = WorkerSnapshot(id: UUID(), name: "b", prompt: "p", status: .done, providerID: .claudeCode)
        let snapshot = RegattaStateSnapshot(workers: [running, done])

        let restored = planner.restoredWorkers(from: snapshot)
        #expect(restored.first(where: { $0.id == running.id })?.status == .interrupted)
        #expect(restored.first(where: { $0.id == done.id })?.status == .done)
        // Identity and definition preserved.
        #expect(restored.first(where: { $0.id == running.id })?.prompt == "p")
    }

    @Test func runningLoopReArmsToIdleKeepingHistory() {
        let history = [
            RegattaIterationRecord(
                index: 0,
                outcome: RegattaLoopOutcome(kind: .progressed, summary: "s", tokensUsed: 5),
                duration: 1
            ),
        ]
        let loop = LoopSnapshot(
            workerID: "w",
            state: RegattaLoopState(
                configuration: RegattaLoopConfiguration(goal: "g", stopCondition: .iterations(9)),
                status: .running,
                history: history
            )
        )
        let snapshot = RegattaStateSnapshot(loops: [loop])

        let restored = planner.restoredLoops(from: snapshot)
        let restoredLoop = try! #require(restored.first)
        #expect(restoredLoop.state.status == .idle)
        #expect(restoredLoop.state.history == history)
        #expect(restoredLoop.state.configuration.goal == "g")
        #expect(restoredLoop.state.configuration.stopCondition == .iterations(9))
    }

    @Test func terminalLoopStatusPreserved() {
        let loop = LoopSnapshot(
            workerID: "w",
            state: RegattaLoopState(
                configuration: RegattaLoopConfiguration(goal: "g"),
                status: .stopped(.goalReached),
                history: []
            )
        )
        let restored = planner.restoredLoops(from: RegattaStateSnapshot(loops: [loop]))
        #expect(restored.first?.state.status == .stopped(.goalReached))
    }
}
