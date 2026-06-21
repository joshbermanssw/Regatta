import Testing
import Foundation
@testable import RegattaCore

/// Tests that the worker output-watching / loop-condition seam is agnostic to the
/// agent provider's output shape (issue #36 acceptance: "Loop conditions, esp.
/// output-match, work across providers").
///
/// The HITL concern is that condition checks might secretly depend on Claude
/// Code's stream-json / assistant-turn output. These tests feed deliberately
/// *non-Claude-shaped* output (plain Codex-style and Gemini-style lines) through
/// the same ``PaneOutputEvent`` stream the orchestrator consumes and confirm an
/// output-match condition fires identically regardless of which provider produced
/// the text — because the condition operates on raw stdout/stderr text, not on
/// any provider-specific envelope.
@Suite("ProviderAgnosticConditions")
struct ProviderAgnosticConditionTests {

    /// Drains a handle's output stream into the concatenated stdout/stderr text the
    /// orchestrator and condition checks observe, mirroring how the live path
    /// accumulates `PaneOutputEvent.stdout`/`.stderr` chunks.
    private func collectOutput(_ events: [PaneOutputEvent]) -> String {
        var text = ""
        for event in events {
            switch event {
            case .stdout(let chunk), .stderr(let chunk):
                text += chunk
            case .terminated:
                break
            }
        }
        return text
    }

    @Test("an output-match condition fires on Claude-shaped output")
    func outputMatchFiresOnClaudeShapedOutput() {
        // Claude Code (stream-json style) line.
        let claudeOutput = collectOutput([
            .stdout("{\"type\":\"assistant\",\"message\":{\"content\":\"All tests passed\"}}\n"),
            .terminated(0),
        ])
        let condition = OutputMatchCondition(needle: "All tests passed")
        #expect(condition.isSatisfied(byOutput: claudeOutput))
    }

    @Test("the same output-match condition fires on Codex-shaped output")
    func outputMatchFiresOnCodexShapedOutput() {
        // Codex `exec` prints plain text, no JSON envelope.
        let codexOutput = collectOutput([
            .stdout("Running tests...\n"),
            .stdout("All tests passed\n"),
            .terminated(0),
        ])
        let condition = OutputMatchCondition(needle: "All tests passed")
        #expect(condition.isSatisfied(byOutput: codexOutput))
    }

    @Test("the same output-match condition fires on Gemini-shaped output")
    func outputMatchFiresOnGeminiShapedOutput() {
        // Gemini CLI prints plain prose, different framing again.
        let geminiOutput = collectOutput([
            .stdout("Done. All tests passed without errors.\n"),
            .terminated(0),
        ])
        let condition = OutputMatchCondition(needle: "All tests passed")
        #expect(condition.isSatisfied(byOutput: geminiOutput))
    }

    @Test("output-match is not satisfied when the needle is absent, regardless of provider")
    func outputMatchNotSatisfiedWhenAbsent() {
        let condition = OutputMatchCondition(needle: "All tests passed")
        #expect(!condition.isSatisfied(byOutput: "1 test failed\n"))
        #expect(!condition.isSatisfied(byOutput: ""))
    }
}
