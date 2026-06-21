/// `Codable` conformance for ``RegattaLoopState`` so a loop's full snapshot —
/// configuration, status, and iteration history — survives an app restart
/// (issue #34, state persistence + session restore).
///
/// `totalTokensUsed` is derived from the history, so it is not encoded; decoding
/// routes through the designated initialiser which recomputes it. This keeps the
/// on-disk form minimal and impossible to desynchronise.
extension RegattaLoopState: Codable {
    private enum CodingKeys: String, CodingKey {
        case configuration
        case status
        case history
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let configuration = try container.decode(RegattaLoopConfiguration.self, forKey: .configuration)
        let status = try container.decode(RegattaLoopStatus.self, forKey: .status)
        let history = try container.decodeIfPresent([RegattaIterationRecord].self, forKey: .history) ?? []
        self.init(configuration: configuration, status: status, history: history)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(status, forKey: .status)
        try container.encode(history, forKey: .history)
    }
}
