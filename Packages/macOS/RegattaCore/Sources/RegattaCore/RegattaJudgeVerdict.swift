/// The brain's assessment of whether a loop's goal has been met after an
/// iteration, produced by a ``RegattaLoopJudge``.
///
/// A verdict is a value type so it can be recorded verbatim in the loop's
/// judging journal (``RegattaLoopJournal``) and surfaced in the UI alongside the
/// iteration history. The ``prompt`` the judge was asked and its ``reasoning``
/// are both captured so a user can audit *why* the loop decided to stop (or keep
/// going) — issue #21's "record the judging prompt/verdict in the iteration
/// history" requirement.
public struct RegattaJudgeVerdict: Equatable, Sendable {
    /// The zero-based index of the iteration this verdict assessed.
    public let iterationIndex: Int

    /// Whether the judge considers the loop's goal met.
    ///
    /// `true` stops the loop (``RegattaLoopStopReason/goalReached``); `false`
    /// lets it continue (subject to the stop condition and safety caps).
    public let goalMet: Bool

    /// The exact prompt the judge was asked, recorded for auditability.
    public let prompt: String

    /// The judge's free-text reasoning for the verdict (the brain's answer).
    public let reasoning: String

    /// Creates a judge verdict.
    ///
    /// - Parameters:
    ///   - iterationIndex: The iteration this verdict assessed.
    ///   - goalMet: Whether the goal is considered met.
    ///   - prompt: The exact prompt the judge was asked.
    ///   - reasoning: The judge's free-text reasoning.
    public init(iterationIndex: Int, goalMet: Bool, prompt: String, reasoning: String) {
        self.iterationIndex = iterationIndex
        self.goalMet = goalMet
        self.prompt = prompt
        self.reasoning = reasoning
    }
}
