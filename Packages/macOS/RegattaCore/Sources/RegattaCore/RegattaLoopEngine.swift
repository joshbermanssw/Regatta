public import Foundation

/// Drives a ``RegattaLoopWorker`` toward a goal across iterations, recording an
/// iteration history and enforcing hard safety caps.
///
/// The engine is the loop state machine. Each turn it: checks the hard caps,
/// runs one worker iteration, records the result, then asks its pluggable
/// ``RegattaLoopCondition`` whether to continue, stop, or fail. A cap always
/// wins over the condition, so a runaway loop is force-stopped and marked
/// stopped-by-cap.
///
/// All mutable state (status + history) lives in this actor; there are no locks
/// and no `@Published`. The UI reads value-typed ``RegattaLoopState`` snapshots
/// via ``state`` (or live via ``stateStream``), never the actor's internals.
///
/// ## Usage
/// ```swift
/// let engine = RegattaLoopEngine(
///     configuration: RegattaLoopConfiguration(
///         goal: "make the tests pass",
///         stopCondition: .iterations(3),
///         safetyCaps: RegattaLoopSafetyCaps(maxIterations: 10, tokenBudget: 50_000)
///     ),
///     worker: myWorker
/// )
/// let finalState = try await engine.run()
/// ```
public actor RegattaLoopEngine {

    // MARK: - Dependencies

    private let configuration: RegattaLoopConfiguration
    private let worker: any RegattaLoopWorker
    private let condition: any RegattaLoopCondition

    /// Injected wall-clock source so tests can measure deterministic durations.
    private let now: @Sendable () -> Date

    // MARK: - State

    private var status: RegattaLoopStatus = .idle
    private var history: [RegattaIterationRecord] = []
    private var totalTokensUsed = 0
    private var manualStopRequested = false
    private var cancelRequested = false

    private var continuations: [UUID: AsyncStream<RegattaLoopState>.Continuation] = [:]

    // MARK: - Init

    /// Creates a loop engine.
    ///
    /// - Parameters:
    ///   - configuration: The goal, stop condition, and safety caps.
    ///   - worker: The worker to wrap; one call per iteration.
    ///   - condition: The pluggable stop condition. Defaults to
    ///     ``RegattaBuiltInLoopCondition`` (manual + `N iterations`).
    ///   - now: A wall-clock source for iteration timing. Defaults to
    ///     `Date.init`; inject a fake for deterministic duration tests.
    public init(
        configuration: RegattaLoopConfiguration,
        worker: any RegattaLoopWorker,
        condition: any RegattaLoopCondition = RegattaBuiltInLoopCondition(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.worker = worker
        self.condition = condition
        self.now = now
    }

    // MARK: - Queryable state

    /// The current value-typed loop-state snapshot, queryable for the UI.
    public var state: RegattaLoopState {
        RegattaLoopState(configuration: configuration, status: status, history: history)
    }

    /// A live stream of loop-state snapshots, yielding the current state
    /// immediately and a fresh snapshot after every transition.
    ///
    /// Lets a `@MainActor @Observable` view model project state without polling.
    /// The stream finishes when the loop reaches a terminal status.
    public func stateStream() -> AsyncStream<RegattaLoopState> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.yield(state)
            if status.isTerminal {
                continuation.finish()
                return
            }
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    // MARK: - Control

    /// Requests that the loop stop after the current iteration completes.
    ///
    /// For a ``RegattaLoopStopCondition/manual`` loop this is the normal way to
    /// end it. The flag is checked at the top of each turn, so an in-flight
    /// iteration always finishes and is recorded before the loop stops with
    /// ``RegattaLoopStopReason/manualStop``.
    public func requestManualStop() {
        manualStopRequested = true
    }

    /// Requests that the loop **cancel** — stop now and never start another
    /// iteration — marking it stopped with ``RegattaLoopStopReason/cancelled``.
    ///
    /// Unlike ``requestManualStop()`` (a graceful "finish the current iteration,
    /// then stop"), a cancel is the user/dismiss "stop" signal: it is checked at
    /// the top of each turn, so an in-flight iteration still finishes and is
    /// recorded, but the loop then terminates as cancelled instead of advancing.
    /// A cancelled iteration outcome (from a killed worker) reaches the same
    /// terminal state. Idempotent and final: a loop already terminal stays so.
    public func requestCancel() {
        cancelRequested = true
    }

    // MARK: - Run

    /// Runs the loop to a terminal status and returns the final state.
    ///
    /// The state machine, per turn:
    /// 1. If a manual stop was requested → stop (`manualStop`).
    /// 2. If a hard cap is already reached → stop (cap reason).
    /// 3. Run one worker iteration; record it (index, outcome, summary,
    ///    duration, tokens).
    /// 4. If the just-recorded tokens pushed the total to/over budget → stop
    ///    (`tokenBudgetCap`).
    /// 5. Otherwise ask the condition: continue / stop / fail.
    ///
    /// A thrown worker error is recorded as a failed iteration and fails the
    /// loop. Calling `run()` on an already-terminal engine returns the existing
    /// state unchanged.
    ///
    /// - Returns: The terminal ``RegattaLoopState``.
    @discardableResult
    public func run() async -> RegattaLoopState {
        guard !status.isTerminal else { return state }
        status = .running

        while true {
            // A cancel (user ✕, shepherd dismiss cascade, or an enclosing
            // cancelled Task) is a final stop, never a retry: terminate as
            // cancelled before starting another iteration.
            if cancelRequested || Task.isCancelled {
                finish(.stopped(.cancelled))
                break
            }
            if manualStopRequested {
                finish(.stopped(.manualStop))
                break
            }
            if let capReason = reachedSafetyCapBeforeIteration() {
                finish(.stopped(capReason))
                break
            }

            let index = history.count
            let started = now()
            let outcome: RegattaLoopOutcome
            do {
                outcome = try await worker.runIteration(index: index, goal: configuration.goal)
            } catch {
                let elapsed = now().timeIntervalSince(started)
                let failedOutcome = RegattaLoopOutcome(
                    kind: .failed,
                    summary: "Worker threw: \(error)",
                    tokensUsed: 0
                )
                record(failedOutcome, index: index, duration: elapsed)
                finish(.failed(summary: failedOutcome.summary))
                break
            }

            let elapsed = now().timeIntervalSince(started)
            record(outcome, index: index, duration: elapsed)

            // A cancelled/killed worker is a final stop — never "iteration
            // finished, not green → advance". The engine decides this directly
            // (ahead of the pluggable condition) so a user cancel can never be
            // reinterpreted by a condition as a reason to spawn the next
            // iteration. This is the loop-respawn-on-cancel fix.
            if outcome.kind == .cancelled {
                finish(.stopped(.cancelled))
                break
            }

            // A completed iteration may push us to/over the token budget; that
            // cap is reported even though the worker outcome itself is fine.
            if let budget = configuration.safetyCaps.tokenBudget, totalTokensUsed >= budget {
                finish(.stopped(.tokenBudgetCap))
                break
            }

            let context = RegattaLoopConditionContext(
                configuration: configuration,
                lastIteration: history[history.count - 1],
                history: history
            )
            let decision = condition.evaluate(context)
            switch decision {
            case .continue:
                continue
            case .stop(let reason):
                finish(.stopped(reason))
            case .fail(let summary):
                finish(.failed(summary: summary))
            }
            break
        }

        return state
    }

    // MARK: - State machine helpers

    /// Returns the cap reason if a hard cap is already reached *before* starting
    /// the next iteration, or `nil` if it is safe to run another.
    private func reachedSafetyCapBeforeIteration() -> RegattaLoopStopReason? {
        if history.count >= configuration.safetyCaps.maxIterations {
            return .maxIterationsCap
        }
        if let budget = configuration.safetyCaps.tokenBudget, totalTokensUsed >= budget {
            return .tokenBudgetCap
        }
        return nil
    }

    /// Appends an iteration record and updates the running token total.
    private func record(_ outcome: RegattaLoopOutcome, index: Int, duration: TimeInterval) {
        let entry = RegattaIterationRecord(index: index, outcome: outcome, duration: duration)
        history.append(entry)
        totalTokensUsed += outcome.tokensUsed
        broadcast()
    }

    /// Transitions to a terminal status and finishes the state stream.
    private func finish(_ terminal: RegattaLoopStatus) {
        status = terminal
        broadcast()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    /// Yields the current state to all live stream subscribers.
    private func broadcast() {
        let snapshot = state
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}
