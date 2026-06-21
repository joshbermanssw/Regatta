import Foundation
import RegattaFleet
import RegattaGitHub

/// A pure, value-typed projection of one shepherd's state into the sections the
/// PR shepherd card renders (issue #33).
///
/// `ShepherdCardModel` is the testable seam between the `@Observable`
/// ``RegattaFleetViewModel`` and the SwiftUI ``FleetSectionView``. It takes the
/// raw inputs — a ``ShepherdState`` snapshot, the PR's pending actions, the
/// optional active fix loop, and the activity log — and computes the derived
/// view data: a CI rollup, per-check rows, per-thread rows with status, and a
/// time-ordered activity list.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// Every field is a pure value; no `Fleet`/`AutonomyGate`/view-model reference is
/// captured. The card view holds a `ShepherdCardModel` value snapshot only.
///
/// ## Why a value, not a method on the view
/// Keeping the projection in a value type (rather than computed properties on
/// the SwiftUI view) lets it be unit-tested with Swift Testing without booting
/// AppKit — see `ShepherdCardModelTests`.
struct ShepherdCardModel: Identifiable, Equatable, Sendable {

    /// Stable identity, derived from the watched PR — one card per PR.
    var id: String { state.pullRequest.id }

    // MARK: - CI

    /// A coarse rollup of the PR's CI state, used for the header dot and label.
    enum CIRollup: Equatable, Sendable {
        /// No checks reported yet.
        case none
        /// At least one check failed.
        case failing
        /// Every check completed successfully.
        case passing
        /// Checks are still queued or in progress.
        case running
    }

    /// One CI check row in the card.
    struct CheckRow: Identifiable, Equatable, Sendable {
        /// Stable identity (the check name).
        var id: String { name }
        /// The check display name.
        let name: String
        /// The per-check status used to pick an icon/colour.
        let status: Status
        /// The check details URL, if any.
        let detailsURL: String?

        /// The rendered status of a single check.
        enum Status: Equatable, Sendable {
            case passed
            case failed
            case running
        }
    }

    // MARK: - Threads

    /// One review-thread row in the card, with its derived per-thread status.
    struct ThreadRow: Identifiable, Equatable, Sendable {
        /// Stable identity (the thread node id).
        let id: String
        /// The file path the thread comments on.
        let path: String
        /// The derived status shown next to the thread.
        let status: ThreadStatus
        /// The latest comment body, truncated for the row, if any.
        let latestComment: String?
    }

    /// Per-thread status surfaced in the card (#31 acceptance criterion).
    ///
    /// Derived from the thread's GitHub state plus whether the shepherd's
    /// account has replied. #31's richer "addressing" signal (a fix in flight)
    /// is fed through the activity log / fix loop seam; here we derive the best
    /// status the base data supports.
    enum ThreadStatus: Equatable, Sendable {
        /// The thread is resolved (or outdated).
        case resolved
        /// The shepherd has replied but the thread is still open.
        case replied
        /// The thread is open and awaiting a response.
        case addressing
    }

    // MARK: - Stored projection

    /// The underlying shepherd snapshot, retained for the header (title, phase).
    let state: ShepherdState

    /// The coarse CI rollup.
    let ciRollup: CIRollup

    /// The per-check rows, in input order.
    let checkRows: [CheckRow]

    /// The per-thread rows (open and recently-actioned), in input order.
    let threadRows: [ThreadRow]

    /// The activity log, newest first.
    let activity: [ShepherdActivityEntry]

    /// The pending approvals for this PR (staged mode), oldest first.
    let pending: [PendingAction]

    /// The active fix loop, if one is running for this PR.
    let fixLoop: ShepherdFixLoopStatus?

    // MARK: - Convenience reads

    /// The number of open (unresolved, non-outdated) threads.
    var openThreadCount: Int {
        threadRows.filter { $0.status != .resolved }.count
    }

    // MARK: - Projection

    /// Projects a shepherd's raw inputs into card sections.
    ///
    /// - Parameters:
    ///   - state: The latest ``ShepherdState`` snapshot.
    ///   - pending: The PR's pending approvals (already filtered to this PR).
    ///   - activity: The PR's activity log (any order; sorted newest-first here).
    ///   - fixLoop: The active fix loop, or `nil` (#30 seam).
    ///   - shepherdLogin: The shepherd's GitHub login, used to detect whether it
    ///     has already replied to a thread. Defaults to `nil` (treats any
    ///     comment beyond the first as a reply signal).
    init(
        state: ShepherdState,
        pending: [PendingAction] = [],
        activity: [ShepherdActivityEntry] = [],
        fixLoop: ShepherdFixLoopStatus? = nil,
        shepherdLogin: String? = nil
    ) {
        self.state = state
        self.pending = pending
        self.fixLoop = fixLoop
        self.activity = activity.sorted { $0.timestamp > $1.timestamp }
        self.ciRollup = Self.rollup(for: state.checks)
        self.checkRows = state.checks.checks.map { Self.checkRow(from: $0) }
        self.threadRows = state.reviewThreads.map {
            Self.threadRow(from: $0, shepherdLogin: shepherdLogin)
        }
    }

    /// Computes the coarse CI rollup from a check summary.
    private static func rollup(for checks: PRCheckSummary) -> CIRollup {
        if checks.checks.isEmpty { return .none }
        if checks.anyFailed { return .failing }
        if checks.allSucceeded { return .passing }
        return .running
    }

    /// Maps a raw ``PRCheck`` into a card check row.
    private static func checkRow(from check: PRCheck) -> CheckRow {
        let status: CheckRow.Status
        if check.status != "COMPLETED" {
            status = .running
        } else if check.conclusion == "SUCCESS" || check.conclusion == "NEUTRAL" || check.conclusion == "SKIPPED" {
            status = .passed
        } else {
            status = .failed
        }
        return CheckRow(name: check.name, status: status, detailsURL: check.detailsURL)
    }

    /// Maps a raw ``ReviewThread`` into a card thread row with derived status.
    private static func threadRow(from thread: ReviewThread, shepherdLogin: String?) -> ThreadRow {
        let status: ThreadStatus
        if thread.isResolved || thread.isOutdated {
            status = .resolved
        } else if Self.hasReplied(thread, shepherdLogin: shepherdLogin) {
            status = .replied
        } else {
            status = .addressing
        }
        return ThreadRow(
            id: thread.id,
            path: thread.path,
            status: status,
            latestComment: thread.comments.last?.body
        )
    }

    /// Whether the shepherd appears to have replied to a thread.
    ///
    /// When a `shepherdLogin` is known, "replied" means the shepherd authored
    /// any comment after the first. Without a known login we fall back to "more
    /// than one comment exists" as a weak signal that the thread has seen a
    /// response.
    private static func hasReplied(_ thread: ReviewThread, shepherdLogin: String?) -> Bool {
        guard thread.comments.count > 1 else { return false }
        guard let login = shepherdLogin else { return true }
        return thread.comments.dropFirst().contains { $0.author == login }
    }
}
