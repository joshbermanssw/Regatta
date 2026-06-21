import Foundation

/// The status of the shepherd's CI-fix loop for one pull request.
///
/// ## Seam for #30
/// The actual ci-fix loop (#30) lives on a sibling branch not yet merged into
/// this base. The card renders an "active fix loop" banner from this value; the
/// view model exposes a per-PR slot (``RegattaFleetViewModel/fixLoop(for:)``)
/// that #30 drives. Until #30 lands the slot stays `nil` and the banner is
/// hidden, so the rest of the card renders identically with or without #30.
///
/// ## Value type
/// Pure `Sendable`/`Equatable` value so it crosses into the `@MainActor` view
/// layer and feeds the card directly.
struct ShepherdFixLoopStatus: Equatable, Sendable {
    /// The phase of the fix loop.
    enum Phase: Equatable, Sendable {
        /// A fix loop is running: the shepherd is producing/pushing a fix.
        case running
        /// The most recent fix loop succeeded (CI went green after a push).
        case succeeded
        /// The most recent fix loop gave up; the message is the reason.
        case gaveUp(String)
    }

    /// The current phase of the loop.
    let phase: Phase

    /// The name of the failing check that triggered the loop, if known.
    let failingCheck: String?

    /// The attempt number (1-based) the loop is currently on.
    let attempt: Int

    /// Creates a fix-loop status.
    ///
    /// - Parameters:
    ///   - phase: The current phase.
    ///   - failingCheck: The failing check name, if known. Defaults to `nil`.
    ///   - attempt: The 1-based attempt number. Defaults to `1`.
    init(phase: Phase, failingCheck: String? = nil, attempt: Int = 1) {
        self.phase = phase
        self.failingCheck = failingCheck
        self.attempt = attempt
    }
}
