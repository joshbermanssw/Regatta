public import Foundation

/// Shared executable-resolution constants for ``AgentProvider`` adapters.
///
/// All bundled providers resolve their CLI through `/usr/bin/env` so the agent
/// binary (`claude`, `codex`, `gemini`) is found on the worker's `PATH` rather
/// than via a hardcoded absolute path. This is a value-only declaration namespace
/// (a static constant, not behavior), so it is exempt from the no-namespace-enum
/// rule.
public enum AgentExecutable {
    /// The `/usr/bin/env` URL used to launch a CLI by name from `PATH`.
    public static let envURL = URL(fileURLWithPath: "/usr/bin/env")
}
