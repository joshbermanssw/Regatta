/// A seam for classifying raw text into a ``MemoryFactType``.
///
/// The default production implementation (``DefaultMemoryFactClassifier``) uses
/// a lightweight keyword/shape heuristic. A future LLM-backed implementation
/// can be swapped in by conforming to this protocol and passing it to
/// ``MemoryArchivist/init(store:classifier:)``.
///
/// ## Thread safety
///
/// Implementations must be `Sendable` so they can be safely captured by the
/// `MemoryArchivist` actor.
public protocol MemoryFactClassifying: Sendable {
    /// Returns the most appropriate ``MemoryFactType`` for `text` given the
    /// optional ambient context string.
    ///
    /// - Parameters:
    ///   - text: The raw text of the fact to classify. Implementations should
    ///     inspect only the first line when identifying the subject; multi-line
    ///     content is acceptable but is typically not needed for classification.
    ///   - context: Optional ambient context (e.g. the scope path or a short
    ///     description of the work that produced the fact). Implementations may
    ///     ignore this if it is not useful to their heuristic.
    func classify(text: String, context: String?) -> MemoryFactType
}

// MARK: - Default implementation

/// A keyword- and shape-based classifier that requires no external calls.
///
/// ## Heuristic rules (applied in priority order)
///
/// 1. **Reference** — the first line contains a URL-like token (starts with
///    `http://`, `https://`, or `ftp://`) or looks like a file-system path
///    (starts with `/` followed by at least one non-space character, or
///    contains `~/`). Rationale: bare URLs and paths are almost always
///    pointers to external resources, not actionable rules or facts.
///
/// 2. **Preference** — the first line (lowercased) contains at least one of
///    the preference markers: `"prefer"`, `"avoid"`, `"use "`, `"don't"`,
///    `"do not"`, `"should "`. Rationale: these words signal stated choices or
///    guidelines rather than discovered patterns or hard facts.
///
/// 3. **Heuristic** — the first line (lowercased) contains at least one of
///    the heuristic markers: `"always"`, `"never"`, `"every time"`,
///    `"each time"`, `"when "`. Rationale: universals and conditionals
///    typically express learned rules derived from agent observations.
///
/// 4. **Fact** — fallback. The text is a concrete datum that does not match
///    any of the patterns above.
///
/// The heuristic deliberately errs toward `fact` for ambiguous input so that
/// higher-value types (preference, heuristic) are reserved for text that
/// clearly signals them. A future LLM-backed classifier can refine this.
public struct DefaultMemoryFactClassifier: MemoryFactClassifying {
    public init() {}

    public func classify(text: String, context: String?) -> MemoryFactType {
        // Use only the first line for classification, as per the conflict-key
        // convention used elsewhere in the package.
        let firstLine = text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? text
        let lowered = firstLine.trimmingCharacters(in: .whitespaces).lowercased()

        // 1. Reference: URL or file-system path.
        if Self.looksLikeReference(lowered) {
            return .reference
        }

        // 2. Preference: stated choice or guideline.
        let preferenceMarkers = ["prefer", "avoid", "use ", "don't", "do not", "should "]
        if preferenceMarkers.contains(where: { lowered.contains($0) }) {
            return .preference
        }

        // 3. Heuristic: universal rule or conditional pattern.
        let heuristicMarkers = ["always", "never", "every time", "each time", "when "]
        if heuristicMarkers.contains(where: { lowered.contains($0) }) {
            return .heuristic
        }

        // 4. Fallback: concrete fact.
        return .fact
    }

    // MARK: Private helpers

    private static func looksLikeReference(_ lowered: String) -> Bool {
        // URL schemes.
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("ftp://") {
            return true
        }
        // Absolute file-system path: "/" followed by a non-space character.
        if lowered.hasPrefix("/") && lowered.count > 1 && lowered.dropFirst().first != " " {
            return true
        }
        // Home-directory tilde path.
        if lowered.contains("~/") {
            return true
        }
        return false
    }
}
