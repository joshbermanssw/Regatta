import Testing
import Foundation
@testable import RegattaCore

/// Behavior tests for the provider-swappable worker abstraction (issue #36).
///
/// Verifies that each ``AgentProvider`` adapter builds the launch spec expected
/// for its CLI, that Claude Code is the default, that the chosen provider is
/// recorded on the spawned ``Worker``, and — critically for the HITL boundary —
/// that output-watching / condition evaluation does not depend on Claude Code's
/// output shape.
@Suite("AgentProvider")
struct AgentProviderTests {

    // MARK: - Provider IDs

    @Test("the default provider id is Claude Code")
    func defaultProviderIsClaudeCode() {
        #expect(AgentProviderID.default == .claudeCode)
    }

    @Test("every provider id has a stable raw value and display name")
    func providerIDsHaveStableRawValues() {
        #expect(AgentProviderID.claudeCode.rawValue == "claude-code")
        #expect(AgentProviderID.codex.rawValue == "codex")
        #expect(AgentProviderID.gemini.rawValue == "gemini")
        for id in AgentProviderID.allCases {
            #expect(!id.displayName.isEmpty)
        }
    }

    // MARK: - Claude Code adapter

    @Test("the Claude Code adapter launches `claude` in non-interactive print mode and appends the prompt")
    func claudeCodeBuildsExpectedLaunch() {
        let provider = ClaudeCodeProvider()
        #expect(provider.id == .claudeCode)

        let launch = provider.makeLaunch(prompt: "fix the bug")
        #expect(launch.executableURL == URL(fileURLWithPath: "/usr/bin/env"))
        // Includes `--dangerously-skip-permissions` so the headless worker can
        // actually edit files + run git/tests (otherwise `-p` print mode emits text
        // and exits with zero changes), plus hook/MCP isolation so workers don't
        // inherit the user's global ~/.claude hooks (the same isolation the Brain
        // uses).
        #expect(launch.arguments == [
            "claude", "-p",
            "--dangerously-skip-permissions",
            "--strict-mcp-config",
            "--settings", "{\"disableAllHooks\":true}",
        ])
        // The headless worker must be able to act without an interactive prompt.
        #expect(launch.arguments.contains("--dangerously-skip-permissions"))
        // The orchestrator appends the prompt as the trailing argument.
        #expect(launch.appendPrompt == true)
    }

    // MARK: - Codex adapter

    @Test("the Codex adapter launches `codex exec` non-interactively and appends the prompt")
    func codexBuildsExpectedLaunch() {
        let provider = CodexProvider()
        #expect(provider.id == .codex)

        let launch = provider.makeLaunch(prompt: "fix the bug")
        #expect(launch.executableURL == URL(fileURLWithPath: "/usr/bin/env"))
        // Includes the autonomous bypass so the headless `codex exec` worker can act.
        #expect(launch.arguments == ["codex", "exec", "--dangerously-bypass-approvals-and-sandbox"])
        #expect(launch.appendPrompt == true)
    }

    // MARK: - Gemini adapter

    @Test("the Gemini adapter launches `gemini -p` non-interactively and appends the prompt")
    func geminiBuildsExpectedLaunch() {
        let provider = GeminiProvider()
        #expect(provider.id == .gemini)

        let launch = provider.makeLaunch(prompt: "fix the bug")
        #expect(launch.executableURL == URL(fileURLWithPath: "/usr/bin/env"))
        // Includes `--yolo` (auto-approve) so the headless Gemini worker can act.
        #expect(launch.arguments == ["gemini", "--yolo", "-p"])
        #expect(launch.appendPrompt == true)
    }

    // MARK: - Provider registry / lookup

    @Test("the provider registry resolves every id to its adapter")
    func registryResolvesEveryID() {
        for id in AgentProviderID.allCases {
            let provider = AgentProviderRegistry.provider(for: id)
            #expect(provider.id == id)
        }
    }

    // MARK: - WorkerSpec records the provider

    @Test("a WorkerSpec built from a provider records the provider id and carries its launch")
    func workerSpecRecordsProvider() {
        let provider = CodexProvider()
        let spec = WorkerSpec(
            name: "Codex worker",
            prompt: "do the thing",
            repoURL: URL(fileURLWithPath: "/tmp/repo"),
            provider: provider
        )
        #expect(spec.providerID == .codex)
        #expect(spec.agentLaunch.arguments == ["codex", "exec", "--dangerously-bypass-approvals-and-sandbox"])
    }

    @Test("a WorkerSpec defaults to the Claude Code provider when none is given")
    func workerSpecDefaultsToClaudeCode() {
        let spec = WorkerSpec(
            name: "Default worker",
            prompt: "do the thing",
            repoURL: URL(fileURLWithPath: "/tmp/repo")
        )
        #expect(spec.providerID == .claudeCode)
        #expect(spec.agentLaunch.arguments == [
            "claude", "-p",
            "--dangerously-skip-permissions",
            "--strict-mcp-config",
            "--settings", "{\"disableAllHooks\":true}",
        ])
    }
}
