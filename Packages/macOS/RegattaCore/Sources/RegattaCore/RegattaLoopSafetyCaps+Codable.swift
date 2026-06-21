/// `Codable` conformance for ``RegattaLoopSafetyCaps`` so a loop's hard caps
/// survive an app restart (issue #34).
///
/// Decoding routes through the designated initialiser so the `maxIterations >= 0`
/// invariant is re-applied to a persisted value rather than trusting the file.
extension RegattaLoopSafetyCaps: Codable {
    private enum CodingKeys: String, CodingKey {
        case maxIterations
        case tokenBudget
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 50
        let tokenBudget = try container.decodeIfPresent(Int.self, forKey: .tokenBudget)
        self.init(maxIterations: maxIterations, tokenBudget: tokenBudget)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxIterations, forKey: .maxIterations)
        try container.encodeIfPresent(tokenBudget, forKey: .tokenBudget)
    }
}
