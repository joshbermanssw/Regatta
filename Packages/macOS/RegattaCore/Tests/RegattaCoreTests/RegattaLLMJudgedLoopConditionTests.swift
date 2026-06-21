import Testing
import Foundation
@testable import RegattaCore

/// Tests for issue #21's `LLM-judged` stop condition: stop the loop when the
/// brain judges the goal met.
///
/// The brain is a STUBBED ``RegattaLoopJudge`` — no network, no live API. The
/// stub returns canned verdicts (with a configurable "goal met" iteration), and
/// the tests assert the loop stops on a positive verdict, keeps going on a
/// negative one (until the safety cap), records the prompt + reasoning in the
/// journal, and fails cleanly when the judge throws.
@Suite struct RegattaLLMJudgedLoopConditionTests {

    // MARK: - Stub judge

    /// A judge stub that returns `goalMet == true` once the iteration index
    /// reaches `stopAtIteration`, recording every request it saw. Optionally
    /// throws on a given iteration to exercise the judge-failure path.
    private actor StubJudge: RegattaLoopJudge {
        private let stopAtIteration: Int
        private let throwAtIteration: Int?
        private(set) var requests: [RegattaJudgeRequest] = []

        init(stopAtIteration: Int, throwAtIteration: Int? = nil) {
            self.stopAtIteration = stopAtIteration
            self.throwAtIteration = throwAtIteration
        }

        struct JudgeBoom: Error {}

        func judge(_ request: RegattaJudgeRequest) async throws -> RegattaJudgeVerdict {
            requests.append(request)
            if request.iterationIndex == throwAtIteration {
                throw JudgeBoom()
            }
            let met = request.iterationIndex >= stopAtIteration
            return RegattaJudgeVerdict(
                iterationIndex: request.iterationIndex,
                goalMet: met,
                prompt: "is goal '\(request.goal)' met after iter \(request.iterationIndex)?",
                reasoning: met ? "yes — tests pass" : "no — still failing"
            )
        }

        func seenRequests() -> [RegattaJudgeRequest] { requests }
    }

    private func progressingWorker() -> RegattaClosureLoopWorker {
        RegattaClosureLoopWorker { index, _ in
            RegattaLoopOutcome(kind: .progressed, summary: "did work \(index)", tokensUsed: 10)
        }
    }

    // MARK: - Positive verdict stops the loop

    /// The loop stops with `goalReached` on the iteration where the judge first
    /// returns "goal met", and the verdict (prompt + reasoning) is recorded.
    @Test func positiveVerdictStopsLoopAndRecordsVerdict() async throws {
        let journal = RegattaLoopJournal()
        let judge = StubJudge(stopAtIteration: 2) // met at iteration 2
        let worker = RegattaLLMJudgedWorker(
            wrapping: progressingWorker(), judge: judge, journal: journal)
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "make the tests pass",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 20)
            ),
            worker: worker,
            condition: RegattaLLMJudgedLoopCondition()
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.goalReached), "got \(final.status)")
        #expect(final.completedIterations == 3, "stops on the iter judged met (index 2); got \(final.completedIterations)")

        // The judging prompt + verdict is recorded in the journal (history).
        let verdicts = await journal.allVerdicts()
        #expect(verdicts.count == 3)
        #expect(verdicts.map(\.goalMet) == [false, false, true])
        let stopping = await journal.verdict(forIteration: 2)
        #expect(stopping?.goalMet == true)
        #expect(stopping?.prompt.contains("make the tests pass") == true)
        #expect(stopping?.reasoning == "yes — tests pass")

        // The stopping iteration's recorded summary surfaces the verdict reasoning.
        #expect(final.history.last?.summary.contains("judge: goal met") == true)
    }

    // MARK: - Negative verdicts continue until the safety cap

    /// A judge that never says "met" lets the loop run until the max-iterations
    /// safety cap force-stops it — the judged condition never bypasses caps.
    @Test func negativeVerdictsRunUntilSafetyCap() async throws {
        let journal = RegattaLoopJournal()
        let judge = StubJudge(stopAtIteration: .max) // never met
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "unsatisfiable",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 5)
            ),
            worker: RegattaLLMJudgedWorker(
                wrapping: progressingWorker(), judge: judge, journal: journal),
            condition: RegattaLLMJudgedLoopCondition()
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.maxIterationsCap), "got \(final.status)")
        #expect(final.completedIterations == 5, "cap clamps to 5; got \(final.completedIterations)")
        let verdicts = await journal.allVerdicts()
        #expect(verdicts.count == 5)
        #expect(verdicts.allSatisfy { !$0.goalMet })
    }

    // MARK: - Token budget cap still applies

    /// The token-budget safety cap stops a judged loop even before the judge
    /// would, proving caps are enforced by the engine on top of the condition.
    @Test func tokenBudgetCapStopsJudgedLoop() async throws {
        let journal = RegattaLoopJournal()
        let judge = StubJudge(stopAtIteration: .max) // never met
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "burns tokens",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 1000, tokenBudget: 25)
            ),
            // Each iteration uses 10 tokens; budget 25 → stops after 3 (total 30).
            worker: RegattaLLMJudgedWorker(
                wrapping: progressingWorker(), judge: judge, journal: journal),
            condition: RegattaLLMJudgedLoopCondition()
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.tokenBudgetCap), "got \(final.status)")
        #expect(final.completedIterations == 3, "30 >= 25 after 3 iters; got \(final.completedIterations)")
    }

    // MARK: - Judge throwing fails the loop cleanly

    /// If the judge throws, the iteration is recorded as failed and the loop
    /// fails — it never spins forever on an unjudgeable iteration.
    @Test func judgeErrorFailsLoop() async throws {
        let journal = RegattaLoopJournal()
        let judge = StubJudge(stopAtIteration: .max, throwAtIteration: 1)
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "judge breaks",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 20)
            ),
            worker: RegattaLLMJudgedWorker(
                wrapping: progressingWorker(), judge: judge, journal: journal),
            condition: RegattaLLMJudgedLoopCondition()
        )

        let final = await engine.run()

        guard case .failed(let summary) = final.status else {
            Issue.record("expected .failed; got \(final.status)")
            return
        }
        #expect(summary.contains("judge failed"), "summary should name the judge failure; got \(summary)")
        #expect(final.completedIterations == 2, "iter 0 judged, iter 1 throws and fails; got \(final.completedIterations)")
    }

    // MARK: - Request carries goal + summaries to the judge

    /// The worker hands the judge the goal, the iteration index, the latest
    /// summary, and the prior summaries so the brain can weigh progress.
    @Test func judgeReceivesGoalAndSummaries() async throws {
        let journal = RegattaLoopJournal()
        let judge = StubJudge(stopAtIteration: 1)
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "ship it", stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 20)),
            worker: RegattaLLMJudgedWorker(
                wrapping: progressingWorker(), judge: judge, journal: journal),
            condition: RegattaLLMJudgedLoopCondition()
        )

        _ = await engine.run()

        let requests = await judge.seenRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.goal == "ship it" })
        #expect(requests[0].iterationIndex == 0)
        #expect(requests[0].priorSummaries.isEmpty)
        #expect(requests[1].iterationIndex == 1)
        #expect(requests[1].priorSummaries.count == 1)
        #expect(requests[1].latestSummary == "did work 1")
    }
}
