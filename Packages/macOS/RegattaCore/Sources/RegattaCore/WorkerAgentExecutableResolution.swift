public import Foundation

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
///
/// Lives in `RegattaCore` (with its pure launch-rewriting helpers) so the spawn
/// wiring it backs can be exercised headlessly under `swift test`. The default
/// resolver — which needs the app's `AgentExecutableResolver` — is provided by the
/// app target as an extension.
public struct WorkerAgentExecutableResolution: Equatable, Sendable {
    /// The absolute path to the agent executable (never `/usr/bin/env`).
    public let executableURL: URL

    /// The complete environment to launch the agent with (inherits the process
    /// environment and augments `PATH` with the executable's directory).
    public let environment: [String: String]

    /// Creates a resolution.
    public init(executableURL: URL, environment: [String: String]) {
        self.executableURL = executableURL
        self.environment = environment
    }
}

/// Resolves a worker's agent CLI to a full executable path + complete environment.
///
/// Injected into the app's `OrchestratorWorkerSpawner` so the **app layer** owns
/// executable resolution (it has access to `AgentExecutableResolver`) while
/// `RegattaCore` stays free of any dependency on the app's resolver. Tests inject
/// a stub.
public typealias WorkerAgentExecutableResolving =
    @Sendable (AgentProviderID) throws -> WorkerAgentExecutableResolution

/// The error surfaced when a worker's agent CLI cannot be resolved to a real
/// on-disk executable — so the failure is a clear "Claude CLI not found" message
/// instead of a cryptic worker exit code 127.
public enum WorkerAgentExecutableResolutionError: LocalizedError, Equatable {
    /// The provider has no resolvable agent-session equivalent (e.g. Gemini, which
    /// cmux's `AgentExecutableResolver` does not know how to locate).
    case unsupportedProvider(displayName: String)

    /// The provider's CLI binary was not found in any searched directory.
    case notFound(displayName: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let displayName):
            return String(
                format: String(
                    localized: "regatta.workerExecutable.unsupported",
                    defaultValue: "%@ cannot be launched as a Regatta worker: its CLI could not be located.",
                    bundle: .module
                ),
                displayName
            )
        case .notFound(let displayName, let underlying):
            return String(
                format: String(
                    localized: "regatta.workerExecutable.notFound",
                    defaultValue: "%1$@ CLI not found. %2$@",
                    bundle: .module
                ),
                displayName,
                underlying
            )
        }
    }
}

extension WorkerAgentExecutableResolution {
    /// Rewrites a provider's PATH-relying ``WorkerAgentLaunch`` into one that runs
    /// the **resolved absolute executable** with a **complete** environment.
    ///
    /// Provider launches target `/usr/bin/env` and prefix their arguments with the
    /// binary name (`["claude", "-p", …]`) so `env` can find the CLI on `PATH`.
    /// Once the executable is the resolved absolute path, that leading binary-name
    /// token is dropped, so the worker runs e.g. `/Users/x/.local/bin/claude -p …`.
    /// The resolver's environment is used as-is because it is already complete
    /// (inherits the process environment + augments `PATH`) — ``ProcessPaneBridge``
    /// *replaces* the child environment when it is non-empty, so a partial one would
    /// strip `HOME` and break the agent's keychain/OAuth auth.
    ///
    /// - Throws: ``WorkerAgentExecutableResolutionError`` when resolution fails.
    public static func resolvedLaunch(
        base: WorkerAgentLaunch,
        providerID: AgentProviderID,
        resolve: WorkerAgentExecutableResolving
    ) throws -> WorkerAgentLaunch {
        let resolution = try resolve(providerID)
        let arguments = strippingBinaryNamePrefix(base.arguments, providerID: providerID)
        return WorkerAgentLaunch(
            executableURL: resolution.executableURL,
            arguments: arguments,
            environment: resolution.environment,
            appendPrompt: base.appendPrompt
        )
    }

    /// Drops the leading binary-name token a provider prefixes for `/usr/bin/env`.
    ///
    /// Only strips the first argument when it matches the provider's executable name
    /// (`claude`/`codex`/`gemini`), so a switch to the resolved absolute executable
    /// does not pass the CLI its own name as the first positional argument. Leaves
    /// args untouched if the prefix is already absent (idempotent).
    public static func strippingBinaryNamePrefix(
        _ arguments: [String],
        providerID: AgentProviderID
    ) -> [String] {
        guard let first = arguments.first,
              first == binaryName(for: providerID) else {
            return arguments
        }
        return Array(arguments.dropFirst())
    }

    /// The CLI binary name a provider's launch prefixes for `/usr/bin/env`.
    private static func binaryName(for providerID: AgentProviderID) -> String {
        switch providerID {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        }
    }
}
