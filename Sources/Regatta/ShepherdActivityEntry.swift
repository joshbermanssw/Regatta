import Foundation

/// One entry in a shepherd's activity log: a timestamped record of an action the
/// shepherd took (or attempted) on the watched pull request.
///
/// ## Seam for #30 / #31
/// The CI-fix loop (#30) and review-thread reply/resolve work (#31) live on
/// sibling branches not yet merged into this base. When they land they feed
/// activity entries into ``RegattaFleetViewModel/recordActivity(_:for:)`` — one
/// entry per push, reply, resolve, or fix-loop transition. Until then the log is
/// driven only by the autonomy gate's approve/reject decisions, which this base
/// already observes.
///
/// ## Value type
/// `ShepherdActivityEntry` is a pure `Sendable`/`Equatable`/`Identifiable` value
/// so it crosses into the `@MainActor` view layer and feeds list rows directly,
/// honouring the snapshot-boundary rule (no store reference escapes a `ForEach`).
struct ShepherdActivityEntry: Identifiable, Equatable, Sendable {
    /// The kind of activity recorded, used to pick an icon and grouping.
    enum Kind: String, Equatable, Sendable {
        /// A commit/push to the PR branch (e.g. a fix the shepherd produced).
        case push
        /// A reply posted to a review thread.
        case reply
        /// A review thread resolved.
        case resolve
        /// A CI-fix loop lifecycle transition (started / fixed / gave up).
        case fixLoop
        /// A generic note (poll failure surfaced, mode changed, etc.).
        case note
    }

    /// Stable identity for this entry.
    let id: UUID

    /// When the activity happened.
    let timestamp: Date

    /// What kind of activity this is.
    let kind: Kind

    /// A short human-readable description, already localized by the producer.
    let summary: String

    /// Creates an activity-log entry.
    ///
    /// - Parameters:
    ///   - id: Stable identity. Defaults to a fresh `UUID`.
    ///   - timestamp: When it happened. Defaults to now.
    ///   - kind: The activity kind.
    ///   - summary: A short, already-localized description.
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        summary: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
    }
}
