/// The recorded outcome of one deterministic check, keyed to the iteration that
/// triggered it.
///
/// ``RegattaDeterministicLoopCondition`` produces one of these after every
/// iteration and accumulates them, keyed by ``iterationIndex``, so the UI can
/// show the per-iteration check result alongside the engine's
/// ``RegattaIterationRecord``. This is how check results "feed the iteration
/// history" without modifying ``RegattaLoopEngine`` — the condition owns its own
/// per-iteration history that aligns 1:1 with the engine's by index.
public struct RegattaDeterministicCheckResult: Equatable, Sendable {
    /// The zero-based engine iteration index this check ran after.
    public let iterationIndex: Int

    /// A short label for the check that produced this result
    /// (see ``RegattaDeterministicCheck/kindLabel``).
    public let kindLabel: String

    /// Whether the check was satisfied (and the loop should therefore stop).
    public let passed: Bool

    /// The exit status of the check command.
    public let exitCode: Int32

    /// A short, human-readable explanation of the result for the history row.
    public let summary: String

    /// Creates a deterministic check result.
    ///
    /// - Parameters:
    ///   - iterationIndex: The engine iteration index this check ran after.
    ///   - kindLabel: The check kind label.
    ///   - passed: Whether the check was satisfied.
    ///   - exitCode: The check command's exit status.
    ///   - summary: A one-line explanation for the history.
    public init(
        iterationIndex: Int,
        kindLabel: String,
        passed: Bool,
        exitCode: Int32,
        summary: String
    ) {
        self.iterationIndex = iterationIndex
        self.kindLabel = kindLabel
        self.passed = passed
        self.exitCode = exitCode
        self.summary = summary
    }
}
