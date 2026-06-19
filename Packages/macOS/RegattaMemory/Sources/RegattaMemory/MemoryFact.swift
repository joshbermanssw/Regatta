public import Foundation

/// A persistent memory fact stored in the Regatta memory subsystem.
///
/// ## Scope paths
///
/// `scopePath` is a "/" -joined string representing the hierarchical namespace
/// this fact belongs to (e.g. `"acme/webapp/billing"` or just `"acme/webapp"`).
/// The empty string `""` denotes the root scope. Using a "/" -joined string (rather
/// than `[String]`) keeps the on-disk JSON readable and makes prefix matching
/// straightforward with `hasPrefix`.
///
/// ## Supersedes history
///
/// When a fact is superseded by a newer fact, the new fact records the IDs of the
/// facts it replaces in `supersedes`. The superseded facts remain retrievable by
/// their original IDs so the full history of how knowledge evolved is preserved.
public struct MemoryFact: Codable, Sendable, Equatable, Identifiable {
    /// A stable UUID-based identifier for this fact. Stable across restarts.
    public var id: String

    /// The text content of the fact.
    public var text: String

    /// The classification of this fact.
    public var type: MemoryFactType

    /// The hierarchical scope this fact applies to, expressed as a "/" -joined
    /// path (e.g. `"acme/webapp/billing"`). The empty string `""` is the root
    /// scope.
    public var scopePath: String

    /// Origin information: which worker recorded this fact, from which PR, and
    /// when.
    public var provenance: MemoryProvenance

    /// When this fact was first created.
    public var createdAt: Date

    /// When this fact was last updated (equal to `createdAt` for new facts that
    /// have never been mutated).
    public var updatedAt: Date

    /// IDs of earlier facts that this fact supersedes. Empty for facts that are
    /// not replacements of previous knowledge.
    public var supersedes: [String]

    public init(
        id: String = UUID().uuidString,
        text: String,
        type: MemoryFactType,
        scopePath: String,
        provenance: MemoryProvenance,
        createdAt: Date,
        updatedAt: Date,
        supersedes: [String] = []
    ) {
        self.id = id
        self.text = text
        self.type = type
        self.scopePath = scopePath
        self.provenance = provenance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.supersedes = supersedes
    }
}
