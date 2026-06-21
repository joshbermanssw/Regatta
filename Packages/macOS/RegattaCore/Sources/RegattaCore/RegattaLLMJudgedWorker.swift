/// A ``RegattaLoopWorker`` decorator implementing issue #21's `LLM-judged` stop
/// condition: after each iteration, ask the brain whether the goal is met.
///
/// It wraps an inner worker and, after each non-failed inner iteration, calls a
/// ``RegattaLoopJudge`` (the brain seam) with the goal and the iteration
/// summaries. The verdict — including the exact prompt asked and the brain's
/// reasoning — is recorded in a ``RegattaLoopJournal`` so it lands in the loop's
/// history. A positive verdict re-stamps the outcome as
/// ``RegattaLoopOutcome/Kind/succeeded`` so the paired
/// ``RegattaLLMJudgedLoopCondition`` stops the loop with
/// ``RegattaLoopStopReason/goalReached``; a negative verdict leaves the inner
/// outcome intact so the loop continues (subject to the engine's safety caps).
///
/// A judge that throws is converted into a `failed` outcome so the loop fails
/// cleanly rather than spinning. The judge is injected, so tests stub the
/// verdict and **never** make a live API call.
public struct RegattaLLMJudgedWorker: RegattaLoopWorker {
    private let inner: any RegattaLoopWorker
    private let judge: any RegattaLoopJudge
    private let journal: RegattaLoopJournal

    /// Creates an LLM-judged worker.
    ///
    /// - Parameters:
    ///   - inner: The underlying per-iteration worker (e.g. the agent worker).
    ///   - judge: The brain seam that assesses completion. Inject a stub in
    ///     tests.
    ///   - journal: The journal to record verdicts (prompt + reasoning) into.
    public init(
        wrapping inner: any RegattaLoopWorker,
        judge: any RegattaLoopJudge,
        journal: RegattaLoopJournal
    ) {
        self.inner = inner
        self.judge = judge
        self.journal = journal
    }

    /// Runs the inner iteration, asks the judge, records the verdict, and
    /// converts a "goal met" verdict into a normal `succeeded` stop.
    public func runIteration(index: Int, goal: String) async throws -> RegattaLoopOutcome {
        let outcome = try await inner.runIteration(index: index, goal: goal)

        guard outcome.kind != .failed else {
            return outcome
        }

        let priorSummaries = (0..<index).map { "iteration \($0)" }
        let request = RegattaJudgeRequest(
            goal: goal,
            iterationIndex: index,
            latestSummary: outcome.summary,
            priorSummaries: priorSummaries
        )

        let verdict: RegattaJudgeVerdict
        do {
            verdict = try await judge.judge(request)
        } catch {
            // A judge failure fails the iteration; the loop fails cleanly rather
            // than treating "couldn't judge" as "keep going forever".
            return RegattaLoopOutcome(
                kind: .failed,
                summary: "\(outcome.summary) — judge failed: \(error)",
                tokensUsed: outcome.tokensUsed
            )
        }

        await journal.record(verdict)

        guard verdict.goalMet else {
            return outcome
        }

        return RegattaLoopOutcome(
            kind: .succeeded,
            summary: "\(outcome.summary) — judge: goal met (\(verdict.reasoning))",
            tokensUsed: outcome.tokensUsed
        )
    }
}
