import Foundation

/// A single transient notification shown in the bottom-right toast stack.
///
/// Toasts are immutable value snapshots projected into the overlay's `ForEach`
/// (snapshot-boundary rule): the overlay never holds a reference to
/// ``RegattaToastCenter`` below its list, only this value plus dismiss closures.
struct RegattaToast: Identifiable, Sendable, Equatable {
    /// A stable identity used by SwiftUI for insert/removal animation and by the
    /// center for manual dismissal.
    let id: UUID

    /// The semantic category, driving icon, color, and auto-dismiss timing.
    let kind: RegattaToastKind

    /// The bold, one-line headline (e.g. `"Handed PR #42 to Regatta"`).
    let title: String

    /// An optional secondary line with detail (e.g. the failure reason).
    let message: String?

    /// When the toast was created, used for stable ordering of the stack.
    let createdAt: Date

    /// The number of coalesced duplicates folded into this toast. `1` means the
    /// toast is shown once; higher values render a `×N` count chip so a burst of
    /// identical results does not overflow the stack.
    var count: Int

    /// Creates a toast.
    ///
    /// - Parameters:
    ///   - id: A stable identity (defaults to a fresh `UUID`).
    ///   - kind: The semantic category.
    ///   - title: The bold headline line.
    ///   - message: An optional secondary detail line.
    ///   - createdAt: The creation timestamp (defaults to now).
    ///   - count: The coalesced duplicate count (defaults to `1`).
    init(
        id: UUID = UUID(),
        kind: RegattaToastKind,
        title: String,
        message: String? = nil,
        createdAt: Date = Date(),
        count: Int = 1
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.createdAt = createdAt
        self.count = count
    }

    /// Two toasts coalesce when they carry the same kind, title, and message, so
    /// a repeated identical result bumps a single toast's count instead of
    /// stacking duplicates.
    func coalesces(with other: RegattaToast) -> Bool {
        kind == other.kind && title == other.title && message == other.message
    }
}
