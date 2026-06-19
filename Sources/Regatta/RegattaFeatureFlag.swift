import Foundation

/// Controls whether the Regatta agent-orchestration UI is active.
/// Reads from an injected `UserDefaults` so it is fully testable without touching `.standard`.
struct RegattaFeatureFlag {
    /// UserDefaults key backing the Regatta feature flag.
    static let flagKey = "regatta.enabled"
    /// Default value when the user has not stored a preference.
    static let defaultValue = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the Regatta feature is enabled.
    var isEnabled: Bool {
        guard defaults.object(forKey: Self.flagKey) != nil else {
            return Self.defaultValue
        }
        return defaults.bool(forKey: Self.flagKey)
    }
}
