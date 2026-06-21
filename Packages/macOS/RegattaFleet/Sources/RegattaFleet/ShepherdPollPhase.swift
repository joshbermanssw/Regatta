/// The polling lifecycle phase of a PR shepherd watcher.
///
/// This describes the *watcher's* own state — whether it has data yet — not the
/// CI conclusion of the PR (that lives in ``ShepherdState/checks``).
public enum ShepherdPollPhase: Sendable, Equatable {
    /// The shepherd was just created and has not completed its first poll.
    case starting
    /// The shepherd has at least one successful poll and is actively watching.
    case watching
    /// The most recent poll failed; the message is the user-facing reason.
    /// The shepherd keeps its last good ``ShepherdState`` data, if any.
    case failed(String)
}
