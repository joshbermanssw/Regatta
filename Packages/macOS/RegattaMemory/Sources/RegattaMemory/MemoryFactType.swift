public import Foundation

/// The classification of a memory fact.
///
/// - `heuristic`: A learned rule or pattern discovered through agent work (e.g.
///   "always run tests before pushing in this repo").
/// - `preference`: A stated user or project preference (e.g. "prefer async/await
///   over completion handlers").
/// - `fact`: A concrete, verifiable datum about the project or environment (e.g.
///   "the staging database URL is …").
/// - `reference`: A pointer or URL to an external resource relevant to the scope.
public enum MemoryFactType: String, Codable, Sendable, CaseIterable {
    case heuristic
    case preference
    case fact
    case reference
}
