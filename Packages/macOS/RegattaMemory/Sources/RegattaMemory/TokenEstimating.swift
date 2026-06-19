/// A seam for token-count estimation used by ``MemoryAllocator``.
///
/// Implement this protocol to plug in a real tokenizer (e.g. a BPE encoder) or
/// a deterministic stub in tests. The default implementation
/// ``DefaultTokenEstimator`` uses a character-based approximation.
///
/// ## Sendable
///
/// Implementations must be `Sendable` so they can be stored on the
/// ``MemoryAllocator`` actor without escaping isolation.
public protocol TokenEstimating: Sendable {
    /// Returns an estimated token count for `text`.
    ///
    /// - Returns: A value >= 1 for any non-empty input. Implementations MAY
    ///   return 0 for the empty string.
    func estimate(_ text: String) -> Int
}

// MARK: - Default implementation

/// A character-based token estimator that approximates GPT-style BPE by dividing
/// the character count by four.
///
/// ## Rule
///
/// `estimate(text) = max(1, text.count / 4)`
///
/// This is a deliberate simplification: GPT tokenizers average roughly 4
/// characters per token for English prose. The divisor of 4 is documented here
/// so callers know exactly what they are getting; tests that need deterministic
/// budgeting should supply a custom ``TokenEstimating`` implementation instead.
public struct DefaultTokenEstimator: TokenEstimating {
    public init() {}

    public func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, text.count / 4)
    }
}
