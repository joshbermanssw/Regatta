/// What a ``RegattaLoopJudge`` is asked to assess after an iteration completes.
///
/// Carries everything the brain needs to decide whether the loop's goal is met:
/// the goal text, the iteration index, that iteration's worker summary, and the
/// summaries of every prior iteration. It is a value type so the judge seam can
/// be stubbed in tests without any live brain or network.
public struct RegattaJudgeRequest: Equatable, Sendable {
    /// The loop's goal — what completion is being judged against.
    public let goal: String

    /// The zero-based index of the iteration being assessed.
    public let iterationIndex: Int

    /// The just-completed iteration's one-line worker summary.
    public let latestSummary: String

    /// The one-line summaries of all prior iterations, in iteration order.
    ///
    /// Lets the judge weigh progress across the loop, not just the latest turn.
    public let priorSummaries: [String]

    /// Creates a judge request.
    ///
    /// - Parameters:
    ///   - goal: The loop's goal text.
    ///   - iterationIndex: The iteration being assessed.
    ///   - latestSummary: The just-completed iteration's summary.
    ///   - priorSummaries: Summaries of all prior iterations.
    public init(
        goal: String,
        iterationIndex: Int,
        latestSummary: String,
        priorSummaries: [String]
    ) {
        self.goal = goal
        self.iterationIndex = iterationIndex
        self.latestSummary = latestSummary
        self.priorSummaries = priorSummaries
    }
}
