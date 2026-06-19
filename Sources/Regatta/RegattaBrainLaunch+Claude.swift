import Foundation
import RegattaBrain

/// Builds the ``BrainLaunch`` that runs `claude` in stream-json mode for the
/// Regatta Brain feature, reusing cmux's existing executable-resolution logic.
///
/// Resolution order mirrors ``AgentSessionProcessStore`` / ``AgentExecutableResolver``:
/// 1. Honour any user-configured custom Claude path from `AgentIntegrationSettingsStore`.
/// 2. Search `PATH`, user runtime directories, and standard macOS locations.
/// 3. Skip cmux's own Claude wrapper shims.
///
/// Chosen flags: `-p --output-format stream-json --input-format stream-json
/// --include-partial-messages --verbose` — exactly the flags
/// `AgentSessionProviderID.claude.launchArguments` uses, ensuring the stream-json
/// wire format that ``BrainSession`` already parses.
enum RegattaBrainLaunch {
    /// Returns a ``BrainLaunch`` for `claude` in stream-json mode.
    ///
    /// - Throws: ``AgentExecutableResolverError`` when `claude` is not found.
    static func makeClaude() throws -> BrainLaunch {
        let resolver = AgentExecutableResolver(
            configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths()
        )
        let plan = try resolver.resolve(.claude)
        return BrainLaunch(
            executableURL: plan.executableURL,
            arguments: plan.arguments,
            environment: plan.environment
        )
    }
}
