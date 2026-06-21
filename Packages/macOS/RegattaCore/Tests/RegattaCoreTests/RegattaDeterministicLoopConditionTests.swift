import Testing
import Foundation
@testable import RegattaCore

/// Tests for ``RegattaDeterministicLoopCondition`` and its evaluators (issue #20).
///
/// The condition is exercised two ways:
/// 1. Headlessly through ``RegattaSubprocessCommandRunner`` running real
///    `true` / `false` / `echo` commands and a trivial test script in a temp
///    directory — proving the evaluators react to real subprocess exit codes and
///    output, agent-agnostically.
/// 2. End-to-end inside ``RegattaLoopEngine`` (composed without modifying the
///    engine), proving a passing check stops the loop with `goalReached`, a
///    never-passing check loops to the safety cap, and check results feed a
///    per-iteration history aligned with the engine's.
@Suite struct RegattaDeterministicLoopConditionTests {

    // MARK: - Helpers

    /// Makes a fresh temp directory for a check to run in, and registers cleanup.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("regatta-cond-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A worker that always reports progress so the loop only ends via the
    /// deterministic condition or a safety cap (never a worker-driven success).
    private func progressingWorker() -> RegattaClosureLoopWorker {
        RegattaClosureLoopWorker { index, _ in
            RegattaLoopOutcome(kind: .progressed, summary: "iter-\(index)")
        }
    }

    // MARK: - command-exits-0 (real subprocess)

    /// `command exits 0` passes for `true` and fails for `false`, driven by a
    /// real subprocess in a temp directory.
    @Test func commandExitsZeroReflectsRealExitCode() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = RegattaSubprocessCommandRunner()

        let pass = RegattaDeterministicLoopCondition(
            check: .commandExitsZero(command: "true"),
            workingDirectory: dir,
            runner: runner
        )
        let fail = RegattaDeterministicLoopCondition(
            check: .commandExitsZero(command: "false"),
            workingDirectory: dir,
            runner: runner
        )

        let ctx = Self.context(iterationIndex: 0)
        #expect(pass.evaluate(ctx) == .stop(.goalReached))
        #expect(fail.evaluate(ctx) == .continue)

        #expect(pass.results.last?.passed == true)
        #expect(pass.results.last?.exitCode == 0)
        #expect(fail.results.last?.passed == false)
        #expect(fail.results.last?.exitCode != 0)
    }

    // MARK: - tests-pass (real trivial script)

    /// `tests pass` runs a trivial script: it does not pass while a sentinel file
    /// is absent and passes once it exists, proving the check is re-evaluated
    /// against real worktree state each iteration.
    @Test func testsPassRunsTrivialScriptAgainstWorktreeState() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // "Tests pass" iff a sentinel file exists in the working directory.
        let condition = RegattaDeterministicLoopCondition(
            check: .testsPass(command: "test -f passing.flag"),
            workingDirectory: dir,
            runner: RegattaSubprocessCommandRunner()
        )

        let ctx0 = Self.context(iterationIndex: 0)
        #expect(condition.evaluate(ctx0) == .continue, "no sentinel yet → keep looping")

        // The "agent" makes the tests pass by creating the sentinel.
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("passing.flag").path,
            contents: nil
        )

        let ctx1 = Self.context(iterationIndex: 1)
        #expect(condition.evaluate(ctx1) == .stop(.goalReached), "sentinel present → goal reached")

        #expect(condition.results.map(\.passed) == [false, true])
        #expect(condition.results.map(\.iterationIndex) == [0, 1])
    }

    // MARK: - output-matches (real echo)

    /// `output matches <regex>` passes when the regex hits the command output and
    /// fails when it does not — independent of the command's exit code.
    @Test func outputMatchesSearchesRealCommandOutput() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = RegattaSubprocessCommandRunner()

        let match = RegattaDeterministicLoopCondition(
            check: .outputMatches(command: "echo BUILD SUCCEEDED", pattern: "BUILD SUCCEEDED"),
            workingDirectory: dir,
            runner: runner
        )
        let noMatch = RegattaDeterministicLoopCondition(
            check: .outputMatches(command: "echo still building", pattern: "BUILD SUCCEEDED"),
            workingDirectory: dir,
            runner: runner
        )

        let ctx = Self.context(iterationIndex: 0)
        #expect(match.evaluate(ctx) == .stop(.goalReached))
        #expect(noMatch.evaluate(ctx) == .continue)
    }

    /// An invalid regex never matches (degrades to "keep looping"), never crashes.
    @Test func invalidRegexNeverMatches() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let condition = RegattaDeterministicLoopCondition(
            check: .outputMatches(command: "echo anything", pattern: "[unterminated"),
            workingDirectory: dir,
            runner: RegattaSubprocessCommandRunner()
        )

        #expect(condition.evaluate(Self.context(iterationIndex: 0)) == .continue)
        #expect(condition.results.last?.passed == false)
    }

    // MARK: - agent-agnostic via fake runner

    /// The decision depends only on the injected command result, not on any
    /// worker/agent output: a fake runner returning exit 0 stops the loop even
    /// though the worker keeps reporting `.progressed`.
    @Test func decisionUsesCheckResultNotWorkerOutput() {
        let runner = FakeCommandRunner(scriptedExitCodes: [0])
        let condition = RegattaDeterministicLoopCondition(
            check: .commandExitsZero(command: "ignored-by-fake"),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            runner: runner
        )

        // Worker says "progressed"; check says exit 0 → stop on goalReached.
        let ctx = Self.context(iterationIndex: 0, kind: .progressed)
        #expect(condition.evaluate(ctx) == .stop(.goalReached))
    }

    /// A `.failed` worker outcome fails the loop before the check ever runs.
    @Test func failedWorkerOutcomeShortCircuitsCheck() {
        let runner = FakeCommandRunner(scriptedExitCodes: [0])
        let condition = RegattaDeterministicLoopCondition(
            check: .commandExitsZero(command: "would-pass"),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            runner: runner
        )

        let ctx = Self.context(iterationIndex: 0, kind: .failed, summary: "boom")
        #expect(condition.evaluate(ctx) == .fail(summary: "boom"))
        #expect(condition.results.isEmpty, "no check should run when the worker failed")
        #expect(runner.callCount == 0)
    }

    // MARK: - end-to-end in the engine (engine NOT modified)

    /// Composed into the real engine: the check fails for two iterations then
    /// passes on the third, stopping the loop with `goalReached` and recording a
    /// check result per iteration aligned with the engine's history.
    @Test func conditionStopsEngineWhenCheckPasses() async {
        let runner = FakeCommandRunner(scriptedExitCodes: [1, 1, 0])
        let condition = RegattaDeterministicLoopCondition(
            check: .commandExitsZero(command: "build && test"),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            runner: runner
        )
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "pass the deterministic check",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 10)
            ),
            worker: progressingWorker(),
            condition: condition
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.goalReached), "got \(final.status)")
        #expect(final.completedIterations == 3, "should stop on the first passing check; got \(final.completedIterations)")

        // Check results feed a per-iteration history aligned with the engine's.
        #expect(condition.results.map(\.iterationIndex) == final.history.map(\.index))
        #expect(condition.results.map(\.passed) == [false, false, true])
    }

    /// A check that never passes loops until the max-iterations safety cap force
    /// stops it — proving the engine's caps still backstop the condition.
    @Test func neverPassingCheckRunsToSafetyCap() async {
        let runner = FakeCommandRunner(scriptedExitCodes: [1]) // always non-zero
        let condition = RegattaDeterministicLoopCondition(
            check: .testsPass(command: "swift test"),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            runner: runner
        )
        let engine = RegattaLoopEngine(
            configuration: RegattaLoopConfiguration(
                goal: "never passes",
                stopCondition: .manual,
                safetyCaps: RegattaLoopSafetyCaps(maxIterations: 4)
            ),
            worker: progressingWorker(),
            condition: condition
        )

        let final = await engine.run()

        #expect(final.status == .stopped(.maxIterationsCap), "got \(final.status)")
        #expect(final.completedIterations == 4)
        #expect(condition.results.count == 4, "one check per iteration")
        #expect(condition.results.allSatisfy { !$0.passed })
    }

    // MARK: - Context builder

    /// Builds a post-iteration context for a single iteration at `iterationIndex`.
    private static func context(
        iterationIndex: Int,
        kind: RegattaLoopOutcome.Kind = .progressed,
        summary: String = "iter"
    ) -> RegattaLoopConditionContext {
        let outcome = RegattaLoopOutcome(kind: kind, summary: summary)
        let record = RegattaIterationRecord(index: iterationIndex, outcome: outcome, duration: 0)
        return RegattaLoopConditionContext(
            configuration: RegattaLoopConfiguration(goal: "g", stopCondition: .manual),
            lastIteration: record,
            history: [record]
        )
    }
}

// MARK: - FakeCommandRunner

/// A deterministic ``RegattaCommandRunning`` fake: returns scripted exit codes
/// (and matching stdout) per call, with no real subprocess.
///
/// Reference type so call count and cursor survive across the engine's serial
/// iterations; the engine actor calls it one iteration at a time, so the
/// unsynchronized cursor is safe (same reasoning as the engine tests' clock).
private final class FakeCommandRunner: RegattaCommandRunning, @unchecked Sendable {
    // Exercised serially by the engine actor (never concurrently); no lock needed.
    private let scriptedExitCodes: [Int32]
    private var cursor = 0
    private(set) var callCount = 0

    init(scriptedExitCodes: [Int32]) {
        self.scriptedExitCodes = scriptedExitCodes
    }

    func run(command: String, in directory: URL) throws -> RegattaCommandResult {
        let code = cursor < scriptedExitCodes.count
            ? scriptedExitCodes[cursor]
            : (scriptedExitCodes.last ?? 0)
        cursor += 1
        callCount += 1
        return RegattaCommandResult(
            exitCode: code,
            stdout: code == 0 ? "OK" : "FAIL",
            stderr: ""
        )
    }
}
