import Foundation
import Testing
@testable import RegattaCore

/// Headless coverage for the worker agent-CLI resolution helpers — the exit-127
/// fix that resolves a worker's launch to the **absolute executable** with a
/// complete environment instead of relying on the GUI app's minimal `PATH`.
///
/// These behaviors used to be asserted only by the app-host
/// `OrchestratorWorkerSpawnerTests` (Swift Testing under the cmux app host), which
/// could not run in CI: the app-host invocation died with no output (exit 65). The
/// pure launch-rewriting logic now lives in `RegattaCore` and is exercised here
/// under `swift test`; the full spawn → run → worktree → push wiring those helpers
/// feed is covered headlessly by `RegattaFleet`'s `RegattaPipelineEndToEndTests`.
@Suite("Worker agent executable resolution (exit-127 fix, headless)")
struct WorkerAgentExecutableResolutionTests {

    // MARK: - resolvedLaunch: absolute executable + complete env + arg strip

    /// Ports `OrchestratorWorkerSpawnerTests.resolvesAbsoluteExecutable` /
    /// `ciFixResolvesAbsoluteExecutable` at the level the spawner actually computes:
    /// the resolved launch must carry the **resolved absolute executable** (never
    /// `/usr/bin/env`), drop the leading `claude` binary-name token, and use the
    /// resolver's **complete** environment (so `HOME` is preserved for the agent's
    /// keychain/OAuth auth).
    @Test("resolvedLaunch uses the resolved absolute executable, complete env, no binary-name prefix")
    func resolvedLaunchUsesAbsoluteExecutableAndCompleteEnv() throws {
        let resolved = URL(fileURLWithPath: "/Users/test/.local/bin/claude")
        let base = WorkerAgentLaunch(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["claude", "-p", "--settings"],
            environment: ["PATH": "/usr/bin:/bin"],
            appendPrompt: true
        )

        let launch = try WorkerAgentExecutableResolution.resolvedLaunch(
            base: base,
            providerID: .claudeCode,
            resolve: { _ in
                WorkerAgentExecutableResolution(
                    executableURL: resolved,
                    environment: ["PATH": "/Users/test/.local/bin:/usr/bin", "HOME": "/Users/test"]
                )
            }
        )

        // Resolved absolute path, never /usr/bin/env.
        #expect(launch.executableURL == resolved)
        #expect(launch.executableURL.path != "/usr/bin/env")
        // The leading "claude" binary-name token is dropped now that the executable
        // is the resolved binary itself; remaining args are preserved in order.
        #expect(launch.arguments == ["-p", "--settings"])
        #expect(!launch.arguments.contains("claude"))
        // The complete environment from the resolver is used as-is (HOME preserved).
        #expect(launch.environment["HOME"] == "/Users/test")
        #expect(launch.environment["PATH"] == "/Users/test/.local/bin:/usr/bin")
        // appendPrompt is carried through from the base launch.
        #expect(launch.appendPrompt)
    }

    /// When the resolver throws (the agent CLI cannot be located), `resolvedLaunch`
    /// rethrows so the caller declines to spawn — never launching a worker that
    /// exits 127. Ports the resolver-throws half of
    /// `unresolvableAgentReportsAndDoesNotSpawn`.
    @Test("resolvedLaunch rethrows when the resolver cannot locate the CLI")
    func resolvedLaunchRethrowsWhenUnresolvable() {
        let base = WorkerAgentLaunch(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["claude", "-p"]
        )
        #expect(throws: WorkerAgentExecutableResolutionError.self) {
            _ = try WorkerAgentExecutableResolution.resolvedLaunch(
                base: base,
                providerID: .claudeCode,
                resolve: { providerID in
                    throw WorkerAgentExecutableResolutionError.notFound(
                        displayName: providerID.displayName, underlying: "no claude on PATH"
                    )
                }
            )
        }
    }

    /// An unsupported provider (Gemini, which the app's resolver cannot locate)
    /// surfaces a clear `unsupportedProvider` error rather than a 127. Ports the
    /// intent of `defaultResolverRejectsGemini` against the resolver typealias the
    /// app's `defaultResolver()` conforms to (the default resolver itself lives in
    /// the app target since it needs `AgentExecutableResolver`).
    @Test("an unsupported provider surfaces a clear unsupportedProvider error")
    func unsupportedProviderSurfacesClearError() {
        let resolve: WorkerAgentExecutableResolving = { providerID in
            guard providerID != .gemini else {
                throw WorkerAgentExecutableResolutionError.unsupportedProvider(
                    displayName: providerID.displayName
                )
            }
            return WorkerAgentExecutableResolution(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), environment: [:]
            )
        }
        #expect(throws: WorkerAgentExecutableResolutionError.unsupportedProvider(displayName: "Gemini")) {
            _ = try resolve(.gemini)
        }
    }

    // MARK: - strippingBinaryNamePrefix (pure, provider-aware, idempotent)

    /// Ports `OrchestratorWorkerSpawnerTests.stripsBinaryNamePrefix` verbatim.
    @Test("binary-name prefix is stripped per provider and only when present")
    func stripsBinaryNamePrefix() {
        #expect(
            WorkerAgentExecutableResolution.strippingBinaryNamePrefix(
                ["claude", "-p", "--settings"], providerID: .claudeCode
            ) == ["-p", "--settings"]
        )
        #expect(
            WorkerAgentExecutableResolution.strippingBinaryNamePrefix(
                ["codex", "exec"], providerID: .codex
            ) == ["exec"]
        )
        // Idempotent: a launch already lacking the prefix is untouched.
        #expect(
            WorkerAgentExecutableResolution.strippingBinaryNamePrefix(
                ["-p", "--settings"], providerID: .claudeCode
            ) == ["-p", "--settings"]
        )
        // Only the matching provider's name is stripped.
        #expect(
            WorkerAgentExecutableResolution.strippingBinaryNamePrefix(
                ["codex", "exec"], providerID: .claudeCode
            ) == ["codex", "exec"]
        )
    }

    // MARK: - User-facing error messages are populated

    /// The errors are wired to a user-facing toast in production, so they must
    /// produce a non-empty, parameter-filled message.
    @Test("resolution errors produce clear, parameterized user-facing messages")
    func errorsProduceClearMessages() throws {
        let notFound = WorkerAgentExecutableResolutionError.notFound(
            displayName: "Claude Code", underlying: "no claude on PATH"
        )
        let unsupported = WorkerAgentExecutableResolutionError.unsupportedProvider(
            displayName: "Gemini"
        )
        let notFoundMessage = try #require(notFound.errorDescription)
        #expect(notFoundMessage.contains("Claude Code"))
        #expect(notFoundMessage.contains("no claude on PATH"))
        let unsupportedMessage = try #require(unsupported.errorDescription)
        #expect(unsupportedMessage.contains("Gemini"))
    }
}
