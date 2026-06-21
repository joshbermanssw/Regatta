/// A loop/stop condition satisfied when a worker's accumulated output contains a
/// substring.
///
/// This is the provider-agnostic output-match check for issue #36. It operates on
/// the raw concatenated `stdout`/`stderr` text produced by any provider's CLI —
/// the text accumulated from the worker's ``PaneOutputEvent`` stream — and does a
/// plain substring search. It deliberately does **not** parse Claude Code's
/// stream-json envelope, assistant-turn framing, or any other provider-specific
/// output shape, so the same condition fires identically whether the producing CLI
/// was Claude Code, Codex, or Gemini.
///
/// > Note: The #20 deterministic conditions evaluate by running shell commands
/// > against the worktree (e.g. `git diff`, a test command), which is inherently
/// > provider-agnostic — they inspect the worktree, not agent output. This
/// > substring check covers the one condition family that *does* read agent output
/// > (output-match), and keeps even that provider-neutral.
///
/// ## Example
/// ```swift
/// let condition = OutputMatchCondition(needle: "All tests passed")
/// condition.isSatisfied(byOutput: collectedStdout) // true if the text contains it
/// ```
public struct OutputMatchCondition: Sendable, Equatable {
    /// The substring whose presence in the worker's output satisfies the condition.
    public let needle: String

    /// Creates an output-match condition.
    ///
    /// - Parameter needle: The substring to search for in the worker's output.
    public init(needle: String) {
        self.needle = needle
    }

    /// Reports whether `output` contains ``needle``.
    ///
    /// - Parameter output: The accumulated `stdout`/`stderr` text of a worker,
    ///   regardless of which provider's CLI produced it.
    /// - Returns: `true` if `output` contains ``needle``.
    public func isSatisfied(byOutput output: String) -> Bool {
        guard !needle.isEmpty else { return false }
        return output.contains(needle)
    }
}
