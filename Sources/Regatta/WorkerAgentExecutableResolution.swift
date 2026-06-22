import Foundation
import RegattaCore

/// The resolved on-disk location and runtime environment for a worker's agent CLI.
///
/// A spawned Fleet/shepherd worker launches its agent (Claude Code, Codex, Gemini)
/// as a subprocess of `Regatta.app`. The GUI app runs with a minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`) that does **not** include the directories
/// where the user's agent CLI actually lives (e.g. `~/.local/bin/claude`), so a
/// launch that relies on `/usr/bin/env claude` to find the binary on `PATH` fails
/// with **exit code 127 ("command not found")**.
///
/// This value carries the *fully resolved* answer instead: the absolute
/// `executableURL` of the binary, plus a **complete** `environment` to run it with.
/// The environment is complete (it inherits the app's process environment and adds
/// the binary's directory to `PATH`) because ``ProcessPaneBridge`` *replaces* the
/// child's environment with a non-empty ``PaneSpec/environment`` rather than
/// merging it — so a partial environment would strip `HOME` and break the agent's
/// keychain/OAuth auth.
struct WorkerAgentExecutableResolution: Equatable, Sendable {
    /// The absolute path to the agent executable (never `/usr/bin/env`).
    let executableURL: URL

    /// The complete environment to launch the agent with (inherits the process
    /// environment and augments `PATH` with the executable's directory).
    let environment: [String: String]
}

/// Resolves a worker's agent CLI to a full executable path + complete environment.
///
/// Injected into ``OrchestratorWorkerSpawner`` so the **app layer** owns executable
/// resolution (it has access to ``AgentExecutableResolver``) while `RegattaCore`
/// stays free of any dependency on the app's resolver. Tests inject a stub.
typealias WorkerAgentExecutableResolving =
    @Sendable (AgentProviderID) throws -> WorkerAgentExecutableResolution

/// The error surfaced when a worker's agent CLI cannot be resolved to a real
/// on-disk executable — so the failure is a clear "Claude CLI not found" message
/// instead of a cryptic worker exit code 127.
enum WorkerAgentExecutableResolutionError: LocalizedError, Equatable {
    /// The provider has no resolvable agent-session equivalent (e.g. Gemini, which
    /// cmux's ``AgentExecutableResolver`` does not know how to locate).
    case unsupportedProvider(displayName: String)

    /// The provider's CLI binary was not found in any searched directory.
    case notFound(displayName: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let displayName):
            return String(
                format: String(
                    localized: "regatta.workerExecutable.unsupported",
                    defaultValue: "%@ cannot be launched as a Regatta worker: its CLI could not be located."
                ),
                displayName
            )
        case .notFound(let displayName, let underlying):
            return String(
                format: String(
                    localized: "regatta.workerExecutable.notFound",
                    defaultValue: "%1$@ CLI not found. %2$@"
                ),
                displayName,
                underlying
            )
        }
    }
}

extension WorkerAgentExecutableResolution {
    /// The default app-layer resolver, backed by cmux's ``AgentExecutableResolver``.
    ///
    /// Maps the worker's ``AgentProviderID`` onto the agent-session provider the
    /// resolver understands, resolves the full executable path + augmented `PATH`,
    /// and returns a **complete** environment. Mirrors how the Brain resolves
    /// `claude` (see `RegattaBrainLaunch+Claude.swift`).
    ///
    /// Honours any user-configured custom Claude path via
    /// ``AgentExecutableResolver/cmuxConfiguredExecutablePaths(defaults:)``.
    static func defaultResolver() -> WorkerAgentExecutableResolving {
        { providerID in
            guard let sessionProvider = sessionProviderID(for: providerID) else {
                throw WorkerAgentExecutableResolutionError.unsupportedProvider(
                    displayName: providerID.displayName
                )
            }
            let resolver = AgentExecutableResolver(
                configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths()
            )
            do {
                let plan = try resolver.resolve(sessionProvider)
                return WorkerAgentExecutableResolution(
                    executableURL: plan.executableURL,
                    environment: plan.environment
                )
            } catch {
                throw WorkerAgentExecutableResolutionError.notFound(
                    displayName: providerID.displayName,
                    underlying: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                )
            }
        }
    }

    /// Maps a worker ``AgentProviderID`` to the ``AgentSessionProviderID`` cmux's
    /// resolver can locate, or `nil` when there is no equivalent.
    static func sessionProviderID(for providerID: AgentProviderID) -> AgentSessionProviderID? {
        switch providerID {
        case .claudeCode: return .claude
        case .codex: return .codex
        case .gemini: return nil
        }
    }
}
