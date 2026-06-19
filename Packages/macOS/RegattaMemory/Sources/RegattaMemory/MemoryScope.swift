/// A value type representing a node in the hierarchical scope namespace.
///
/// ## Scope paths
///
/// Scopes are expressed as "/" -delimited strings (e.g. `"acme/webapp/billing"`).
/// The empty string `""` is the root scope, which is an ancestor of every other
/// scope.
///
/// ## Hierarchy rules
///
/// - A scope is its own ancestor at depth 0 (itself is the "nearest" ancestor).
/// - `ancestors()` returns the chain from root (most distant) to self (nearest).
/// - `isAncestor(of:)` is `true` when `self` is a strict prefix of `other` — i.e.
///   `self` is above `other` in the tree and is NOT the same node.
///
/// ## Usage
///
/// ```swift
/// let scope = MemoryScope(path: "acme/webapp/billing")
/// scope.depth          // 2
/// scope.ancestors()    // [MemoryScope(""), MemoryScope("acme"),
///                      //  MemoryScope("acme/webapp"), MemoryScope("acme/webapp/billing")]
/// scope.isAncestor(of: MemoryScope(path: "acme/webapp/billing/vat")) // true
/// ```
public struct MemoryScope: Hashable, Sendable, Comparable {

    // MARK: - Stored property

    /// The "/" -joined path string for this scope node.
    ///
    /// `""` is the root scope (applies to every descendant). Single-segment
    /// paths such as `"acme"` have no `/`. Multi-segment paths such as
    /// `"acme/webapp/billing"` use `/` as the separator. Leading and trailing
    /// slashes, and empty segments, are not permitted and are stripped during
    /// init.
    public let path: String

    // MARK: - Init

    /// Creates a `MemoryScope` from a "/" -joined path string.
    ///
    /// Leading/trailing slashes and empty interior segments are collapsed:
    /// `"/acme//webapp/"` normalises to `"acme/webapp"`.
    /// The empty string (or a path that collapses to empty) is the root scope.
    public init(path: String) {
        if path.isEmpty {
            self.path = ""
        } else {
            // Strip leading/trailing slashes, then drop empty segments.
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            self.path = components.joined(separator: "/")
        }
    }

    // MARK: - Computed properties

    /// The individual path components of this scope.
    ///
    /// Returns `[]` for the root scope (`""`).
    public var components: [String] {
        guard !path.isEmpty else { return [] }
        return path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// The number of "/" separators in the path, i.e. the nesting depth.
    ///
    /// The root scope has depth `0`. `"acme"` has depth `0`. `"acme/webapp"`
    /// has depth `1`. `"acme/webapp/billing"` has depth `2`.
    ///
    /// Depth equals `components.count - 1` (or 0 for the root).
    public var depth: Int {
        let c = components.count
        return c == 0 ? 0 : c - 1
    }

    // MARK: - Ancestry

    /// Returns the full ancestry chain from the root scope down to (and
    /// including) this scope, ordered from most-distant ancestor to self.
    ///
    /// For `"acme/webapp/billing"` this returns:
    /// ```
    /// [MemoryScope(""), MemoryScope("acme"), MemoryScope("acme/webapp"),
    ///  MemoryScope("acme/webapp/billing")]
    /// ```
    ///
    /// For the root scope `""` this returns `[MemoryScope("")]`.
    public func ancestors() -> [MemoryScope] {
        var result: [MemoryScope] = [MemoryScope(path: "")]
        let parts = components
        for index in parts.indices {
            let ancestorPath = parts[0...index].joined(separator: "/")
            let ancestor = MemoryScope(path: ancestorPath)
            if ancestor != MemoryScope(path: "") {
                result.append(ancestor)
            }
        }
        return result
    }

    /// Returns `true` if `self` is a **strict** ancestor of `other` — i.e.
    /// `self` is above `other` in the scope tree and `self != other`.
    ///
    /// The root scope (`""`) is a strict ancestor of every non-root scope.
    /// A scope is NOT considered an ancestor of itself.
    public func isAncestor(of other: MemoryScope) -> Bool {
        guard self != other else { return false }
        if path.isEmpty { return true }
        return other.path.hasPrefix(path + "/")
    }

    // MARK: - Comparable

    /// Lexicographic ordering by path.
    public static func < (lhs: MemoryScope, rhs: MemoryScope) -> Bool {
        lhs.path < rhs.path
    }
}
