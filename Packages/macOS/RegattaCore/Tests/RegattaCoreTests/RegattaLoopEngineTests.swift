import Testing
import Foundation
@testable import RegattaCore

/// Tests for ``RegattaLoopEngine`` (issue #19).
///
/// The loop wraps an injectable ``RegattaLoopWorker``. These tests drive the
/// engine two ways: with the headless `fake-agent.sh` harness (#10) wrapped in a
/// ``RegattaClosureLoopWorker`` — proving the engine composes over a real
/// spawned process — and with a deterministic counting worker for the cap and
/// history assertions.
@Suite struct RegattaLoopEngineTests {

    // MARK: - Fake-agent-backed worker

    /// A worker that spawns `fake-agent.sh` once per iteration, mapping a
    /// per-iteration exit code to a ``RegattaLoopOutcome``: exit 0 → succeeded,
    /// non-zero → progressed. Token usage is the stdout byte count so the
    /// token-budget cap can be exercised through real process output.
    private func fakeAgentWorker(
        perIterationExitCodes: [Int32]
    ) -> RegattaClosureLoopWorker {
        let agent = FakeAgent()
        return RegattaClosureLoopWorker { index, _ in
            let code = index < perIterationExitCodes.count
                ? perIterationExitCodes[index]
                : (perIterationExitCodes.last ?? 0)
            let script = FakeAgentScript(
                steps: [.out("iteration-\(index)")],
                exitCode: code
            )
            let run = try await agent.run(script)
            return RegattaLoopOutcome(
                kind: run.exitCode == 0 ? .succeeded : .progressed,
                summary: "exit=\(run.exitCode) out=\(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines))",
                tokensUsed: run.stdout.utf8.count
            )
        }
    }

    // MARK: - manualStopEndsLoop

    /// A manual loop runs until ``requestManualStop()`` is honored, and the stop
    /// reason is `manualStop`. Driven by the fake-agent harness (worker always
    /// progresses), with a worker that flips the stop flag on its 3rd run.
    @Test func manualStopEndsLoopWithFakeAgent() async throws {
        let agent = FakeAgent()
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "run until told to stop",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 100)
            ),
            worker: RegattaClosureLoopWorker { index, _ in
                // Always "progressed" (exit 1) so the built-in condition never
                // stops a manual loop on its own.
                let run = try await agent.run(FakeAgentScript(steps: [.out("i\(index)")], exitCode: 1))
                return RegattaLoopOutcome(kind: .progressed, summary: run.stdout, tokensUsed: 0)
            }
        )

        // Stop after the 3rd iteration completes.
        let stopper = Task {
            // Poll the queryable state until 3 iterations are recorded, then stop.
            while await engine.state.completedIterations < 3 {
                await Task.yield()
            }
            await engine.requestManualStop()
        }

        let final = await engine.run()
        stopper.cancel()

        #expect(final.status == .stopped(.manualStop), "got \(final.status)")
        #expect(final.completedIterations >= 3, "should have run at least 3 iterations; got \(final.completedIterations)")
    }

    // MARK: - nIterationsStops

    /// An `N iterations` loop stops after exactly N iterations with reason
    /// `iterationCountMet`, recording N history entries (index/summary/duration).
    /// Driven by the fake-agent harness where every iteration progresses.
    @Test func nIterationsStopsAndRecordsHistory() async throws {
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "iterate exactly four times",
                stopCondition: .iterations(4),
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 100)
            ),
            // All progress (exit 1) so the loop runs the full N, not stopping on success.
            worker: fakeAgentWorker(perIterationExitCodes: [1, 1, 1, 1, 1, 1])
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.iterationCountMet), "got \(final.status)")
        #expect(final.completedIterations == 4, "expected 4 iterations; got \(final.completedIterations)")

        // History is fully recorded: ordered indices + non-negative durations + summaries.
        #expect(final.history.map(\.index) == [0, 1, 2, 3])
        for record in final.history {
            #expect(record.duration >= 0, "duration should be non-negative; got \(record.duration)")
            #expect(record.summary.contains("iteration-\(record.index)"), "summary: \(record.summary)")
        }
    }

    // MARK: - successStopsEarly

    /// A worker reporting `.succeeded` (fake-agent exit 0) stops the loop with
    /// `goalReached` before the iteration count is met.
    @Test func successfulIterationStopsEarly() async throws {
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "stop as soon as goal reached",
                stopCondition: .iterations(10)
            ),
            // Two progress runs (exit 1) then a success run (exit 0).
            worker: fakeAgentWorker(perIterationExitCodes: [1, 1, 0])
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.goalReached), "got \(final.status)")
        #expect(final.completedIterations == 3, "should stop on first success at index 2; got \(final.completedIterations)")
    }

    // MARK: - maxIterationsCap

    /// A manual loop that never stops itself is force-stopped by the
    /// max-iterations safety cap and marked stopped-by-cap.
    @Test func maxIterationsCapForceStops() async throws {
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "runaway",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 5)
            ),
            worker: fakeAgentWorker(perIterationExitCodes: [1])  // always progress
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.maxIterationsCap), "got \(final.status)")
        #expect(final.completedIterations == 5, "cap should clamp to 5; got \(final.completedIterations)")
        if case .stopped(let reason) = final.status {
            #expect(reason.isSafetyCap, "max-iterations cap must be marked a safety cap")
        }
    }

    // MARK: - tokenBudgetCap

    /// A token budget force-stops a manual loop that would otherwise run forever,
    /// marking it stopped-by-cap once the running total reaches the budget.
    @Test func tokenBudgetCapForceStops() async throws {
        // Each iteration uses 100 tokens; budget 250 → stops after 3 iterations
        // (total 300 >= 250), never starting a 4th.
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "runaway tokens",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 1000, tokenBudget: 250)
            ),
            worker: RegattaClosureLoopWorker { index, _ in
                RegattaLoopOutcome(kind: .progressed, summary: "i\(index)", tokensUsed: 100)
            }
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.tokenBudgetCap), "got \(final.status)")
        #expect(final.completedIterations == 3, "should stop once total tokens reach budget; got \(final.completedIterations)")
        #expect(final.totalTokensUsed == 300, "total tokens should be summed across history; got \(final.totalTokensUsed)")
        if case .stopped(let reason) = final.status {
            #expect(reason.isSafetyCap, "token-budget cap must be marked a safety cap")
        }
    }

    // MARK: - failedIterationFailsLoop

    /// A `.failed` worker outcome (fake-agent — modeled directly here) transitions
    /// the loop to `.failed` and records the failing iteration.
    @Test func failedIterationFailsLoop() async throws {
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "fails on second iteration",
                stopCondition: .iterations(10)
            ),
            worker: RegattaClosureLoopWorker { index, _ in
                if index == 1 {
                    return RegattaLoopOutcome(kind: .failed, summary: "boom at \(index)")
                }
                return RegattaLoopOutcome(kind: .progressed, summary: "ok \(index)")
            }
        )

        let final = await engine.run()

        #expect(final.status == .failed(summary: "boom at 1"), "got \(final.status)")
        #expect(final.completedIterations == 2, "should record the failing iteration; got \(final.completedIterations)")
        #expect(final.history.last?.outcome.kind == .failed)
    }

    // MARK: - thrownWorkerErrorFailsLoop

    /// A worker that throws is treated as a failed iteration and fails the loop,
    /// recording an iteration whose summary names the error.
    @Test func thrownWorkerErrorFailsLoop() async throws {
        struct WorkerBoom: Error {}
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(goal: "throws immediately", stopCondition: .iterations(5)),
            worker: RegattaClosureLoopWorker { _, _ in throw WorkerBoom() }
        )

        let final = await engine.run()

        guard case .failed(let summary) = final.status else {
            Issue.record("expected .failed; got \(final.status)")
            return
        }
        #expect(summary.contains("WorkerBoom"), "summary should name the error; got \(summary)")
        #expect(final.completedIterations == 1, "the thrown iteration should be recorded; got \(final.completedIterations)")
    }

    // MARK: - zeroIterationsStopsImmediately

    /// A `maxIterations: 0` cap stops the loop immediately without ever running
    /// the worker, leaving an empty history.
    @Test func zeroMaxIterationsStopsImmediately() async throws {
        let ran = RanFlag()
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "never runs",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 0)
            ),
            worker: RegattaClosureLoopWorker { _, _ in
                await ran.markRan()
                return RegattaLoopOutcome(kind: .progressed, summary: "should not happen")
            }
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.maxIterationsCap), "got \(final.status)")
        #expect(final.completedIterations == 0)
        #expect(await ran.didRun == false, "worker must not run when maxIterations is 0")
    }

    // MARK: - deterministicDurations

    /// With an injected clock, iteration durations are deterministic — proving
    /// duration is measured per-iteration from the engine's clock seam, not the
    /// wall clock.
    @Test func injectedClockYieldsDeterministicDurations() async throws {
        // Clock advances 1 second per read. Each iteration reads `now` twice
        // (start + end), consecutive reads, so each duration is exactly 1 second.
        let counter = TickCounter()
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(goal: "timed", stopCondition: .iterations(3)),
            worker: RegattaClosureLoopWorker { index, _ in
                RegattaLoopOutcome(kind: .progressed, summary: "i\(index)")
            },
            now: { counter.next() }
        )

        let final = await engine.run()

        #expect(final.completedIterations == 3)
        for record in final.history {
            #expect(record.duration == 1.0, "expected 1s per iteration; got \(record.duration)")
        }
    }

    // MARK: - stateStreamProjectsTransitions

    /// The live state stream yields the running snapshots and finishes at the
    /// terminal status, so a UI view model can project transitions without
    /// polling.
    @Test func stateStreamYieldsTransitionsThenFinishes() async throws {
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(goal: "stream", stopCondition: .iterations(2)),
            worker: RegattaClosureLoopWorker { index, _ in
                RegattaLoopOutcome(kind: .progressed, summary: "i\(index)")
            }
        )

        let stream = await engine.stateStream()
        // Drain the stream concurrently while the loop runs.
        let collector = Task {
            var statuses: [RegattaLoopStatus] = []
            for await snapshot in stream {
                statuses.append(snapshot.status)
            }
            return statuses
        }

        let final = await engine.run()
        let statuses = await collector.value

        #expect(final.status == .stopped(.iterationCountMet))
        #expect(statuses.last == .stopped(.iterationCountMet), "stream's last snapshot should be terminal; got \(String(describing: statuses.last))")
    }

    // MARK: - Cancel stops the loop (regression for the runaway respawn)

    /// A worker whose iteration outcome is `.cancelled` (a user ✕ / killed worker)
    /// stops the loop as `.cancelled` and does NOT advance to another iteration,
    /// even when the stop condition would otherwise continue. This is the engine
    /// half of the "cancel stops the loop, never respawns" fix.
    @Test func cancelledIterationStopsLoopWithoutAdvancing() async {
        let attempts = CountActor()
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "should stop on cancel, not advance",
                // A 10-iteration loop would normally keep going.
                stopCondition: .iterations(10),
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 10)
            ),
            worker: RegattaClosureLoopWorker { _, _ in
                await attempts.increment()
                // The very first iteration is cancelled (worker killed mid-run).
                return RegattaLoopOutcome(kind: .cancelled, summary: "killed", tokensUsed: 0)
            }
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.cancelled), "got \(final.status)")
        // Exactly one iteration ran — the loop did not spawn a replacement.
        #expect(await attempts.count == 1)
        #expect(final.completedIterations == 1)
    }

    /// `requestCancel()` before the loop starts stops it immediately as
    /// `.cancelled` without running any iteration (the dismiss-cascade contract).
    @Test func requestCancelBeforeRunStopsImmediately() async {
        let attempts = CountActor()
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "cancel before any iteration",
                stopCondition: .iterations(5),
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 5)
            ),
            worker: RegattaClosureLoopWorker { _, _ in
                await attempts.increment()
                return RegattaLoopOutcome(kind: .progressed, summary: "ran", tokensUsed: 0)
            }
        )

        await engine.requestCancel()
        let final = await engine.run()

        #expect(final.status == .stopped(.cancelled), "got \(final.status)")
        #expect(await attempts.count == 0, "no iteration should run after a pre-cancel")
    }

    /// `requestCancel()` mid-loop stops it on the next turn as `.cancelled`,
    /// finishing the in-flight iteration first (so no partial work is lost) but
    /// never starting another. Deterministic: the first iteration requests the
    /// cancel itself (via the shared gate), so by the next turn the flag is set —
    /// no timing race, no cap reliance.
    @Test func requestCancelMidLoopStopsNextTurn() async {
        let attempts = CountActor()
        let gate = CancelGate()
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "cancel mid-loop",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 100)
            ),
            worker: RegattaClosureLoopWorker { index, _ in
                await attempts.increment()
                // After the first iteration completes, fire the cancel so the
                // engine's next top-of-turn check stops the loop deterministically.
                if index == 0 { await gate.fire() }
                return RegattaLoopOutcome(kind: .progressed, summary: "ran", tokensUsed: 0)
            }
        )
        await gate.bind(engine)

        let final = await engine.run()

        #expect(final.status == .stopped(.cancelled), "got \(final.status)")
        // Stopped on the turn after the first iteration: exactly one ran, and the
        // stop is a cancel (not a safety cap).
        #expect(await attempts.count == 1)
        if case .stopped(let reason) = final.status {
            #expect(reason.isSafetyCap == false)
        }
    }
}

// MARK: - CancelGate

/// Lets a worker closure request the engine's cancel after an iteration, so the
/// "cancel mid-loop" test is deterministic rather than timing-dependent.
private actor CancelGate {
    private var engine: RegattaLoopEngine?
    func bind(_ engine: RegattaLoopEngine) { self.engine = engine }
    func fire() async { await engine?.requestCancel() }
}

// MARK: - CountActor

/// A tiny actor that counts worker invocations across the loop's iterations.
private actor CountActor {
    private(set) var count = 0
    func increment() { count += 1 }
}

// MARK: - RanFlag

/// A tiny actor that records whether the worker ran, for the
/// ``zeroMaxIterationsStopsImmediately`` test.
private actor RanFlag {
    private(set) var didRun = false
    func markRan() { didRun = true }
}

// MARK: - TickCounter

/// A deterministic monotonic clock: each ``next()`` advances 1 second.
///
/// Reference type so the closure passed to the engine shares mutable tick state
/// across reads.
private final class TickCounter: @unchecked Sendable {
    // The engine reads `now` serially within its own actor isolation (one read at
    // a time, never concurrently), so this unsynchronized counter is safe.
    private var ticks = 0
    private let base = Date(timeIntervalSince1970: 0)

    func next() -> Date {
        defer { ticks += 1 }
        return base.addingTimeInterval(Double(ticks))
    }
}
