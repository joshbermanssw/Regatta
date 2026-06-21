import Foundation

/// Reads the Regatta Fleet concurrency cap — the maximum number of workers allowed
/// to run at once before the rest are held ``WorkerStatus/queued`` (issue #18).
///
/// Backed by an injected `UserDefaults` so it is fully testable without touching
/// `.standard`. The value is set from `~/.config/cmux/cmux.json`
/// (`regatta.maxConcurrentWorkers`) via the settings file store and surfaced in
/// Settings > Regatta, keeping a single source of truth per CLAUDE.md config
/// policy.
struct RegattaConcurrencySettings {
    /// UserDefaults key backing the Fleet concurrency cap.
    static let maxConcurrentWorkersKey = "regatta.maxConcurrentWorkers"

    /// Default cap when the user has not stored a preference. Matches
    /// `RegattaOrchestrator.defaultMaxConcurrentWorkers`.
    static let defaultMaxConcurrentWorkers = 4

    /// Smallest accepted cap; values below this are clamped up.
    static let minimumMaxConcurrentWorkers = 1

    /// Largest accepted cap; values above this are clamped down so a typo can't ask
    /// the machine to launch an unbounded fleet.
    static let maximumMaxConcurrentWorkers = 64

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The resolved Fleet concurrency cap, clamped to the supported range.
    var maxConcurrentWorkers: Int {
        guard defaults.object(forKey: Self.maxConcurrentWorkersKey) != nil else {
            return Self.defaultMaxConcurrentWorkers
        }
        let raw = defaults.integer(forKey: Self.maxConcurrentWorkersKey)
        return Self.clamp(raw)
    }

    /// Clamps `value` into the supported `[minimum, maximum]` cap range.
    static func clamp(_ value: Int) -> Int {
        min(maximumMaxConcurrentWorkers, max(minimumMaxConcurrentWorkers, value))
    }
}
