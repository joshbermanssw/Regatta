import Foundation
import RegattaCore

// The `WorkerAgentExecutableResolution` value type, its `WorkerAgentExecutableResolving`
// resolver typealias, the `WorkerAgentExecutableResolutionError`, and the pure
// launch-rewriting helpers (`resolvedLaunch`, `strippingBinaryNamePrefix`) now live
// in `RegattaCore` so they can be exercised headlessly under `swift test`. This file
// keeps only the **default resolver**, which depends on the app target's
// `AgentExecutableResolver` and therefore cannot live in the package.

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
