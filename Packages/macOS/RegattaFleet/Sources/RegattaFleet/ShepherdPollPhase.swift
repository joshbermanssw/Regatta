public import Foundation

/// The polling lifecycle phase of a PR shepherd watcher.
///
/// This describes the *watcher's* own state — whether it has data yet — not the
/// CI conclusion of the PR (that lives in ``ShepherdState/checks``).
public enum ShepherdPollPhase: Sendable, Equatable {
    /// The shepherd was just created and has not completed its first poll.
    case starting
    /// The shepherd has at least one successful poll and is actively watching.
    case watching
    /// The most recent poll failed transiently; the message is the user-facing
    /// reason. The shepherd keeps its last good ``ShepherdState`` data, if any,
    /// and retries on its normal interval.
    case failed(String)
    /// The shepherd paused itself after a `gh` auth or rate-limit failure and is
    /// backing off before retrying (issue #35). It keeps its last good data and
    /// surfaces a banner with the reason; `retryAfter` is the backoff delay until
    /// the next poll attempt. Distinct from ``failed`` so the UI can show a
    /// "paused, retrying in N s" banner rather than a transient error.
    case paused(reason: String, retryAfter: Duration)

    /// Whether the shepherd is paused and backing off after an auth/rate-limit
    /// failure. The UI shows a prominent pause banner for this phase.
    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}
