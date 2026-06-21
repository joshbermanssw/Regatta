/// The kind of entity occupying a slot in the Regatta Fleet.
///
/// The Fleet hosts two fundamentally different lifetimes:
/// - ``worker`` — an ephemeral agent that runs a task and disappears when done.
/// - ``shepherd`` — a long-lived watcher (e.g. a PR shepherd) that persists and
///   reacts to external events until the user dismisses it.
///
/// Rendering uses this to keep persistent shepherds visually distinct from
/// transient workers in the Fleet section.
public enum FleetEntryKind: String, Sendable, Equatable, Codable {
    /// An ephemeral worker that ends when its task completes.
    case worker
    /// A persistent watcher that lives until explicitly dismissed.
    case shepherd
}

/// The minimal contract a Fleet entry must satisfy to appear in the Fleet
/// section, independent of the full orchestrator entity model from issue #16.
///
/// Defining the seam here lets the PR shepherd (#29) ship before #16 lands. When
/// the orchestrator's richer Fleet entity arrives, it can either adopt this
/// protocol directly or this protocol can be lifted into the shared core; either
/// way the shepherd already conforms.
public protocol FleetEntry: Sendable, Identifiable where ID == String {
    /// A stable identity unique within the Fleet.
    var id: String { get }
    /// Whether this entry is an ephemeral worker or a persistent shepherd.
    var kind: FleetEntryKind { get }
    /// A short human-readable title shown as the row label.
    var title: String { get }
}
