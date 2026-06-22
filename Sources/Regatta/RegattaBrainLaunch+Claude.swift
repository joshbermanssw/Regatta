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
/// wire format that ``BrainSession`` parses.
///
/// On top of those, the Brain appends *isolation* flags so it starts fast and
/// reliably regardless of the user's global Claude Code config:
/// - `--strict-mcp-config` (with no `--mcp-config`): ignore every globally
///   configured MCP server, so MCP startup latency and failures can't delay or
///   wedge the Brain.
/// - `--settings '{"disableAllHooks":true}'`: skip the user's global
///   SessionStart / hook plugins (Vercel, superpowers, etc.) that otherwise run
///   on every launch and add latency/noise. Auth (OAuth/keychain) is preserved
///   — unlike `--bare`, which forces `ANTHROPIC_API_KEY`-only auth and would
///   break OAuth users.
enum RegattaBrainLaunch {
    /// Extra arguments appended to the shared Claude launch flags to isolate the
    /// Brain from the user's heavy global agent configuration. Kept here (not in
    /// the shared ``AgentSessionProviderID/launchArguments``) so the main
    /// agent-session feature is unaffected.
    static let isolationArguments: [String] = [
        "--strict-mcp-config",
        "--settings", #"{"disableAllHooks":true}"#,
    ]

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
            arguments: plan.arguments + isolationArguments,
            environment: plan.environment
        )
    }
}
