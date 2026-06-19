import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Tests for the Regatta fake-agent harness (issue #10).
///
/// These tests verify that `fake-agent.sh` can be driven by a fixture (output + exit code +
/// sleep schedule) and that the Swift `FakeAgent` helper spawns it correctly via `Process`,
/// matching the real agent spawn path in `AgentSessionProcessStore.swift`.
///
/// All fixtures are intentionally tiny to stay safely under the pipe buffer limit and keep the
/// test suite fast. Each test creates its own `FakeAgent` instance with per-run UUID temp
/// fixture files — parallel-safe by design.
@Suite struct FakeAgentHarnessTests {
    private let agent = FakeAgent()

    // MARK: - emitsOutputAndExitCode

    /// Verifies that OUT directives appear on stdout in order and exit code is captured.
    @Test func emitsOutputAndExitCode() throws {
        let script = FakeAgentScript(
            steps: [.out("hello"), .out("world")],
            exitCode: 0
        )

        let result = try agent.run(script)

        #expect(result.stdout.contains("hello"), "stdout should contain 'hello'; got: \(result.stdout)")
        #expect(result.stdout.contains("world"), "stdout should contain 'world'; got: \(result.stdout)")

        // Verify order: "hello" appears before "world"
        let helloRange = result.stdout.range(of: "hello")
        let worldRange = result.stdout.range(of: "world")
        let h = try #require(helloRange, "'hello' not found in stdout")
        let w = try #require(worldRange, "'world' not found in stdout")
        #expect(h.lowerBound < w.lowerBound, "'hello' should appear before 'world'")

        #expect(result.exitCode == 0)
    }

    // MARK: - nonZeroExitAndStderr

    /// Verifies that ERR directives appear on stderr and non-zero exit codes are captured.
    @Test func nonZeroExitAndStderr() throws {
        let script = FakeAgentScript(
            steps: [.err("something went wrong")],
            exitCode: 3
        )

        let result = try agent.run(script)

        #expect(
            result.stderr.contains("something went wrong"),
            "stderr should contain the error line; got: \(result.stderr)"
        )
        #expect(result.exitCode == 3)
    }

    // MARK: - loopStopsOnSuccess

    /// Verifies that `loop(scripts:maxIterations:)` stops on the first exit-0 run and that
    /// per-run results are correct. Also exercises the SLEEP directive (10 ms) in the second
    /// iteration to confirm the schedule directive works without slowing the suite.
    @Test func loopStopsOnSuccess() throws {
        // Build three scripts: first two fail (exit 1), third succeeds (exit 0).
        let failScript1 = FakeAgentScript(steps: [.out("try1")], exitCode: 1)
        let failScript2 = FakeAgentScript(steps: [.sleepMs(10), .out("try2")], exitCode: 1)
        let successScript = FakeAgentScript(steps: [.out("ok")], exitCode: 0)

        let results = try agent.loop(
            scripts: [failScript1, failScript2, successScript],
            maxIterations: 5
        )

        // Should have run exactly 3 times (stopped on first success at index 2)
        #expect(results.count == 3, "loop should stop after the first exit-0 run; got \(results.count) runs")

        // First two iterations must be non-zero
        #expect(results[0].exitCode != 0, "iteration 0 should fail")
        #expect(results[1].exitCode != 0, "iteration 1 should fail")

        // Third iteration must be the success
        #expect(results[2].exitCode == 0, "iteration 2 should succeed")
        #expect(
            results[2].stdout.contains("ok"),
            "final iteration stdout should contain 'ok'; got: \(results[2].stdout)"
        )

        // Verify per-run stdout matches fixture content
        #expect(results[0].stdout.contains("try1"), "iteration 0 stdout: \(results[0].stdout)")
        #expect(results[1].stdout.contains("try2"), "iteration 1 stdout: \(results[1].stdout)")
    }

    // MARK: - loopRespectsMaxIterations

    /// Verifies that `maxIterations` caps the total number of runs even when all scripts fail.
    @Test func loopRespectsMaxIterations() throws {
        let alwaysFail = FakeAgentScript(steps: [.out("fail")], exitCode: 1)

        let results = try agent.loop(
            scripts: [alwaysFail, alwaysFail, alwaysFail],
            maxIterations: 2
        )

        #expect(results.count == 2, "maxIterations:2 should cap runs at 2; got \(results.count)")
        #expect(results[0].exitCode != 0)
        #expect(results[1].exitCode != 0)
    }
}
