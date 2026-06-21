import Foundation
import Testing
import RegattaCore
@testable import RegattaLoopUI

/// Behavioral tests for ``RegattaLoopViewModel``: state projection from the
/// engine's `stateStream()`, and the control-action intents (start, pause,
/// resume, stop, edit, jump into terminal).
@MainActor
@Suite struct RegattaLoopViewModelTests {

    // MARK: - Helpers

    /// A worker that always reports `progressed` (never self-stops), so the loop
    /// runs until its stop condition or a cap.
    private func progressWorker(tokens: Int = 10) -> any RegattaLoopWorker {
        RegattaClosureLoopWorker { index, _ in
            RegattaLoopOutcome(kind: .progressed, summary: "iter \(index)", tokensUsed: tokens)
        }
    }

    private func makeViewModel(
        configuration: RegattaLoopConfiguration,
        worker: any RegattaLoopWorker,
        jumper: any RegattaLoopTerminalJumping = RegattaLoopTerminalJumpUnavailable()
    ) -> RegattaLoopViewModel {
        RegattaLoopViewModel(
            configuration: configuration,
            workerID: "worker-1",
            engineProvider: FakeEngineProvider(worker: worker),
            terminalJumper: jumper
        )
    }

    // MARK: - State projection

    @Test func startsIdle() {
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(goal: "g"),
            worker: progressWorker()
        )
        #expect(vm.phase == .idle)
        #expect(vm.iterations.isEmpty)
        #expect(vm.totalTokensUsed == 0)
        #expect(vm.stopReason == nil)
    }

    @Test func runsIterationsAndProjectsHistory() async {
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(
                goal: "make tests pass",
                stopCondition: .iterations(3)
            ),
            worker: progressWorker(tokens: 7)
        )
        vm.start()

        let finished = await vm.waitUntil { if case .finished = $0.phase { return true }; return false }
        #expect(finished)
        #expect(vm.iterations.count == 3)
        #expect(vm.iterations.map(\.index) == [0, 1, 2])
        #expect(vm.iterations.allSatisfy { $0.kind == .progressed })
        #expect(vm.totalTokensUsed == 21)
        #expect(vm.stopReason == .iterationCountMet)
    }

    @Test func goalReachedStopsLoop() async {
        let worker = RegattaClosureLoopWorker { _, _ in
            RegattaLoopOutcome(kind: .succeeded, summary: "done", tokensUsed: 3)
        }
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(goal: "g", stopCondition: .manual),
            worker: worker
        )
        vm.start()
        _ = await vm.waitUntil { if case .finished = $0.phase { return true }; return false }
        #expect(vm.stopReason == .goalReached)
        #expect(vm.iterations.count == 1)
    }

    @Test func failedIterationFinishesAsFailed() async {
        let worker = RegattaClosureLoopWorker { _, _ in
            RegattaLoopOutcome(kind: .failed, summary: "boom", tokensUsed: 1)
        }
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(goal: "g", stopCondition: .manual),
            worker: worker
        )
        vm.start()
        _ = await vm.waitUntil {
            if case .finished(.failed) = $0.phase { return true }
            return false
        }
        #expect(vm.failureSummary == "boom")
        #expect(vm.iterations.last?.kind == .failed)
    }

    @Test func maxIterationsCapForceStops() async {
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(
                goal: "g",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 2)
            ),
            worker: progressWorker()
        )
        vm.start()
        _ = await vm.waitUntil { if case .finished = $0.phase { return true }; return false }
        #expect(vm.stopReason == .maxIterationsCap)
        #expect(vm.iterations.count == 2)
    }

    // MARK: - Control intents

    @Test func startIsNoOpWhileRunning() async {
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(goal: "g", stopCondition: .iterations(50)),
            worker: progressWorker()
        )
        vm.start()
        _ = await vm.waitUntil { $0.phase.isActive }
        // Re-entrant start must not spawn a second engine.
        let before = vm.iterations.count
        vm.start()
        #expect(vm.phase.isActive || { if case .finished = vm.phase { return true }; return false }())
        // Tidy up so the long loop doesn't run forever.
        vm.stop()
        _ = await vm.waitUntil { if case .finished = $0.phase { return true }; return false }
        #expect(vm.iterations.count >= before)
    }

    @Test func pauseSettlesIntoPausedThenResumeContinues() async {
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(goal: "g", stopCondition: .manual),
            worker: progressWorker(tokens: 5)
        )
        vm.start()
        _ = await vm.waitUntil { $0.iterations.count >= 1 && $0.phase.isActive }
        vm.pause()
        let paused = await vm.waitUntil { $0.phase == .paused }
        #expect(paused)
        let afterPauseCount = vm.iterations.count
        #expect(afterPauseCount >= 1)

        // Resume builds a fresh engine; history is retained and grows.
        vm.resume()
        _ = await vm.waitUntil { $0.iterations.count > afterPauseCount }
        #expect(vm.iterations.count > afterPauseCount)
        // Row ids stay unique and contiguous across the resume boundary.
        #expect(vm.iterations.map(\.index) == Array(0..<vm.iterations.count))

        vm.stop()
        _ = await vm.waitUntil { if case .finished = $0.phase { return true }; return false }
    }

    @Test func stopFinishesWithManualStop() async {
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(goal: "g", stopCondition: .manual),
            worker: progressWorker()
        )
        vm.start()
        _ = await vm.waitUntil { $0.iterations.count >= 1 && $0.phase.isActive }
        vm.stop()
        let done = await vm.waitUntil { if case .finished = $0.phase { return true }; return false }
        #expect(done)
        #expect(vm.stopReason == .manualStop)
    }

    @Test func editGatingAndCommit() async {
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(goal: "old", stopCondition: .manual),
            worker: progressWorker()
        )
        // Editable while idle.
        #expect(vm.canEdit)
        vm.beginEdit()
        #expect(vm.phase == .editing)

        let newConfig = RegattaLoopConfiguration(
            goal: "new goal",
            stopCondition: .iterations(2),
            safetyCaps: RegattaLoopSafetyCaps(maxIterations: 99, tokenBudget: 1234)
        )
        vm.commitEdit(newConfig)
        #expect(vm.configuration.goal == "new goal")
        #expect(vm.configuration.stopCondition == .iterations(2))
        #expect(vm.configuration.safetyCaps.tokenBudget == 1234)
        #expect(vm.phase == .idle)

        // Running the edited config uses the new stop condition.
        vm.start()
        _ = await vm.waitUntil { if case .finished = $0.phase { return true }; return false }
        #expect(vm.iterations.count == 2)
    }

    @Test func cannotEditWhileRunning() async {
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(goal: "g", stopCondition: .manual),
            worker: progressWorker()
        )
        vm.start()
        _ = await vm.waitUntil { $0.phase.isActive }
        #expect(!vm.canEdit)
        vm.beginEdit()
        #expect(vm.phase != .editing)
        vm.stop()
        _ = await vm.waitUntil { if case .finished = $0.phase { return true }; return false }
    }

    @Test func cancelEditRestoresPhase() {
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(goal: "g"),
            worker: progressWorker()
        )
        vm.beginEdit()
        #expect(vm.phase == .editing)
        vm.cancelEdit()
        #expect(vm.phase == .idle)
        #expect(vm.configuration.goal == "g")
    }

    // MARK: - Terminal jump seam (#16/#17)

    @Test func jumpIntoTerminalDisabledWhenUnavailable() {
        let jumper = FakeTerminalJumper(canJump: false)
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(goal: "g"),
            worker: progressWorker(),
            jumper: jumper
        )
        #expect(!vm.canJumpIntoTerminal)
        vm.jumpIntoTerminal()
        #expect(jumper.jumpedWorkerIDs.isEmpty)
    }

    @Test func jumpIntoTerminalForwardsWorkerIDWhenAvailable() {
        let jumper = FakeTerminalJumper(canJump: true)
        let vm = makeViewModel(
            configuration: RegattaLoopConfiguration(goal: "g"),
            worker: progressWorker(),
            jumper: jumper
        )
        #expect(vm.canJumpIntoTerminal)
        vm.jumpIntoTerminal()
        #expect(jumper.jumpedWorkerIDs == ["worker-1"])
    }
}
