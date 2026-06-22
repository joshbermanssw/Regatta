import Foundation
import RegattaFleet

/// The outcome of resolving a pull request to hand off to Regatta.
///
/// Drives the toast emitted by the handoff action: ``resolved`` shows a success
/// toast, the others show an error/info toast explaining exactly why no shepherd
/// was created — so the handoff is never a silent no-op.
enum RegattaHandoffResolution: Equatable, Sendable {
    /// A PR was resolved and should be handed off.
    case resolved(PullRequestRef)
    /// The workspace has no detectable context (no directory selected).
    case noContext
    /// The workspace is on a branch but no open PR was found for it.
    case noPullRequest(branch: String?)
    /// `gh` is not authenticated; the user must run `gh auth login`.
    case authFailure
    /// `gh` failed for some other reason (timeout, launch failure, parse error).
    case failure(String)
}
