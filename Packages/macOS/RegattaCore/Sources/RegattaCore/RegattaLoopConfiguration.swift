/// The immutable configuration that turns a worker into a loop.
///
/// Combines the goal, the normal ``RegattaLoopStopCondition``, and the hard
/// ``RegattaLoopSafetyCaps``. This is the value the UI captures when a user
/// configures "run this worker as a loop toward goal X for N iterations".
public struct RegattaLoopConfiguration: Equatable, Sendable, Codable {
    /// A human-readable description of what the loop is trying to achieve.
    ///
    /// Recorded with the loop state so the UI can show the goal alongside the
    /// iteration history.
    public let goal: String

    /// The normal stop condition (``RegattaLoopStopCondition/manual`` or
    /// ``RegattaLoopStopCondition/iterations(_:)``).
    public let stopCondition: RegattaLoopStopCondition

    /// The hard safety caps that backstop a runaway loop.
    public let safetyCaps: RegattaLoopSafetyCaps

    /// Creates a loop configuration.
    ///
    /// - Parameters:
    ///   - goal: A human-readable goal description.
    ///   - stopCondition: The normal stop condition (default
    ///     ``RegattaLoopStopCondition/manual``).
    ///   - safetyCaps: The hard safety caps (default ``RegattaLoopSafetyCaps``).
    public init(
        goal: String,
        stopCondition: RegattaLoopStopCondition = .manual,
        safetyCaps: RegattaLoopSafetyCaps = RegattaLoopSafetyCaps()
    ) {
        self.goal = goal
        self.stopCondition = stopCondition
        self.safetyCaps = safetyCaps
    }
}
