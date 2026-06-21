/// A ``RegattaLoopWorker`` backed by a closure, for lightweight composition and
/// testing.
///
/// Lets a caller turn `(index, goal) -> outcome` into a worker without declaring
/// a type. Tests use this to wrap a `fake-agent.sh` spawn:
///
/// ```swift
/// let worker = RegattaClosureLoopWorker { index, _ in
///     let run = try fakeAgent.run(scriptForIteration(index))
///     return RegattaLoopOutcome(
///         kind: run.exitCode == 0 ? .succeeded : .progressed,
///         summary: run.stdout,
///         tokensUsed: run.stdout.count
///     )
/// }
/// ```
public struct RegattaClosureLoopWorker: RegattaLoopWorker {
    private let body: @Sendable (Int, String) async throws -> RegattaLoopOutcome

    /// Creates a closure-backed worker.
    ///
    /// - Parameter body: Runs one iteration; receives the iteration index and
    ///   goal, returns the outcome.
    public init(_ body: @escaping @Sendable (Int, String) async throws -> RegattaLoopOutcome) {
        self.body = body
    }

    /// Forwards to the wrapped closure.
    public func runIteration(index: Int, goal: String) async throws -> RegattaLoopOutcome {
        try await body(index, goal)
    }
}
