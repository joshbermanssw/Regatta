/// The brain seam for issue #21's LLM-judged stop condition.
///
/// A judge assesses, after an iteration, whether the loop's goal is met. The
/// production conformer (``RegattaBrainLoopJudge`` in the `RegattaBrain`
/// package) drives the persistent Claude Code brain session; tests inject a
/// stub that returns canned verdicts, so the LLM-judged condition is exercised
/// **without any live API call**.
///
/// This is a dependency-inversion seam: `RegattaCore` owns the protocol and the
/// value types it trades in (``RegattaJudgeRequest`` / ``RegattaJudgeVerdict``),
/// and the brain-backed implementation lives one layer up. `RegattaCore` never
/// imports `RegattaBrain`.
public protocol RegattaLoopJudge: Sendable {
    /// Assesses whether the loop's goal is met after an iteration.
    ///
    /// - Parameter request: The goal, the iteration index, and the iteration
    ///   summaries to assess.
    /// - Returns: The verdict, carrying the prompt asked and the reasoning so
    ///   both can be recorded in the loop's judging journal.
    /// - Throws: Any error reaching or parsing the brain; the LLM-judged worker
    ///   treats a thrown error as a failed iteration so the loop fails cleanly
    ///   rather than spinning.
    func judge(_ request: RegattaJudgeRequest) async throws -> RegattaJudgeVerdict
}
