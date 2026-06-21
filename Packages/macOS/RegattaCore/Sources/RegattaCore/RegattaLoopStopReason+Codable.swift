/// Tolerant `Codable` conformance for ``RegattaLoopStopReason`` so a loop's
/// terminal reason survives an app restart (issue #34).
///
/// The reason is encoded as a single string tag. Decoding is **tolerant**: an
/// unrecognised tag — for instance a new stop reason added by issue #35's
/// error-handling work, or a value written by a newer build — decodes to
/// ``RegattaLoopStopReason/manualStop`` rather than throwing. This keeps a
/// persisted snapshot loadable even as the enum grows.
extension RegattaLoopStopReason: Codable {
    private var tag: String {
        switch self {
        case .goalReached: return "goalReached"
        case .iterationCountMet: return "iterationCountMet"
        case .manualStop: return "manualStop"
        case .maxIterationsCap: return "maxIterationsCap"
        case .tokenBudgetCap: return "tokenBudgetCap"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let tag = try container.decode(String.self)
        switch tag {
        case "goalReached": self = .goalReached
        case "iterationCountMet": self = .iterationCountMet
        case "manualStop": self = .manualStop
        case "maxIterationsCap": self = .maxIterationsCap
        case "tokenBudgetCap": self = .tokenBudgetCap
        // Tolerant fallback for unknown/added cases (e.g. #35). A manual stop is
        // the safest neutral terminal reason to restore.
        default: self = .manualStop
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tag)
    }
}
