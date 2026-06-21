public import Foundation

/// A ``RegattaLoopCondition`` that stops the loop when a deterministic,
/// agent-agnostic check passes (issue #20).
///
/// After every iteration the engine calls ``evaluate(_:)``; this condition runs
/// its ``RegattaDeterministicCheck`` in the worker's worktree via an injected
/// ``RegattaCommandRunning`` and:
///
/// - **passes** → stops the loop with ``RegattaLoopStopReason/goalReached``,
/// - **fails** → returns ``RegattaLoopDecision/continue`` so the worker iterates
///   again (the engine's safety caps still backstop a runaway loop),
/// - and it always records a ``RegattaDeterministicCheckResult`` keyed by the
///   iteration index, so the check outcome feeds the iteration history without
///   touching ``RegattaLoopEngine``.
///
/// A worker outcome of ``RegattaLoopOutcome/Kind/failed`` is still honored first
/// (the loop fails) so a crashed agent does not get masked by a check; the check
/// only decides *normal* completion. Because the decision depends only on the
/// command's exit status / output, the same condition works regardless of which
/// agent produced the iteration.
///
/// ## Usage
/// ```swift
/// let condition = RegattaDeterministicLoopCondition(
///     check: .testsPass(command: "swift test"),
///     workingDirectory: worktree.path
/// )
/// let engine = RegattaLoopEngine(
///     configuration: config,
///     worker: worker,
///     condition: condition
/// )
/// await engine.run()
/// let checks = condition.results  // per-iteration check history for the UI
/// ```
/// `@unchecked Sendable`: the only mutable state (``recordedResults``) is guarded
/// by ``lock`` for every access; all other stored properties are immutable `let`s.
public final class RegattaDeterministicLoopCondition: RegattaLoopCondition, @unchecked Sendable {

    /// The deterministic check this condition evaluates each iteration.
    private let check: RegattaDeterministicCheck

    /// The directory the check command runs in — the worker's worktree.
    private let workingDirectory: URL

    /// The seam that actually runs the check command.
    private let runner: any RegattaCommandRunning

    /// Per-iteration check results, guarded by ``lock``.
    private var recordedResults: [RegattaDeterministicCheckResult] = []

    // NSLock guards a small append-only results array read by the UI on another
    // thread while the engine actor writes it serially. Approved lock carve-out
    // per cmux-architecture: a short, non-blocking critical section over a tiny
    // collection, not ongoing domain state — promoting to an actor would force
    // the synchronous, non-mutating `evaluate(_:)` protocol method through a
    // `Task { await … }` hop it cannot make.
    private let lock = NSLock()

    /// Creates a deterministic loop condition.
    ///
    /// - Parameters:
    ///   - check: The deterministic check to run after each iteration.
    ///   - workingDirectory: The directory the check runs in (the worker's
    ///     worktree path, e.g. `worktree.path`).
    ///   - runner: The command runner seam. Defaults to
    ///     ``RegattaSubprocessCommandRunner``; tests inject a fake.
    public init(
        check: RegattaDeterministicCheck,
        workingDirectory: URL,
        runner: any RegattaCommandRunning = RegattaSubprocessCommandRunner()
    ) {
        self.check = check
        self.workingDirectory = workingDirectory
        self.runner = runner
    }

    /// The per-iteration check results recorded so far, in iteration order.
    ///
    /// Aligned 1:1 with the engine's ``RegattaIterationRecord`` history by
    /// ``RegattaDeterministicCheckResult/iterationIndex``, so the UI can render
    /// the check outcome next to each iteration.
    public var results: [RegattaDeterministicCheckResult] {
        lock.lock()
        defer { lock.unlock() }
        return recordedResults
    }

    /// Runs the check for the just-completed iteration and decides the next move.
    ///
    /// - Parameter context: The post-iteration context.
    /// - Returns: ``RegattaLoopDecision/stop(_:)`` with
    ///   ``RegattaLoopStopReason/goalReached`` if the check passes;
    ///   ``RegattaLoopDecision/fail(summary:)`` if the worker itself failed; and
    ///   ``RegattaLoopDecision/continue`` otherwise.
    public func evaluate(_ context: RegattaLoopConditionContext) -> RegattaLoopDecision {
        // A failed worker outcome fails the loop before any check runs, so a
        // crashed agent is never masked by a passing/non-passing check.
        if context.lastIteration.outcome.kind == .failed {
            return .fail(summary: context.lastIteration.summary)
        }

        let result = runCheck(forIteration: context.lastIteration.index)
        appendResult(result)

        return result.passed ? .stop(.goalReached) : .continue
    }

    /// Runs the configured check and classifies it into a result value.
    private func runCheck(forIteration index: Int) -> RegattaDeterministicCheckResult {
        let commandResult: RegattaCommandResult
        do {
            commandResult = try runner.run(command: check.command, in: workingDirectory)
        } catch {
            return RegattaDeterministicCheckResult(
                iterationIndex: index,
                kindLabel: check.kindLabel,
                passed: false,
                exitCode: -1,
                summary: "\(check.kindLabel): check could not run (\(error))"
            )
        }

        switch check {
        case .testsPass, .commandExitsZero:
            let passed = commandResult.exitCode == 0
            return RegattaDeterministicCheckResult(
                iterationIndex: index,
                kindLabel: check.kindLabel,
                passed: passed,
                exitCode: commandResult.exitCode,
                summary: "\(check.kindLabel): exit=\(commandResult.exitCode) → \(passed ? "passed" : "not yet")"
            )

        case .outputMatches(_, let pattern):
            let haystack = commandResult.stdout + "\n" + commandResult.stderr
            let matched = Self.regexMatches(pattern: pattern, in: haystack)
            return RegattaDeterministicCheckResult(
                iterationIndex: index,
                kindLabel: check.kindLabel,
                passed: matched,
                exitCode: commandResult.exitCode,
                summary: "\(check.kindLabel): /\(pattern)/ \(matched ? "matched" : "no match") (exit=\(commandResult.exitCode))"
            )
        }
    }

    /// Appends a result to the guarded store.
    private func appendResult(_ result: RegattaDeterministicCheckResult) {
        lock.lock()
        recordedResults.append(result)
        lock.unlock()
    }

    /// Returns whether `pattern` finds a match anywhere in `text`.
    ///
    /// An invalid pattern returns `false` (the check simply never matches) so a
    /// typo in the user's regex degrades to "keep looping", never a crash.
    private static func regexMatches(pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
