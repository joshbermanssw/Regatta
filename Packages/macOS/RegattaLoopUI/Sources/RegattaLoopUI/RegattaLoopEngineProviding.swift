public import RegattaCore

/// A factory seam that builds a fresh ``RegattaLoopEngine`` for a given
/// configuration.
///
/// The loop engine is immutable: it takes its configuration at `init` and has no
/// pause/edit API. The view model therefore treats "edit the goal/condition/caps"
/// and "resume after pause" as *building a new engine* with the updated (or same)
/// configuration and the same worker. This protocol is that build seam.
///
/// It is also the test seam: a fake provider hands back an engine wrapping a
/// canned ``RegattaLoopWorker`` so the view model can be exercised without any
/// real agent process.
public protocol RegattaLoopEngineProviding: Sendable {
    /// Builds a loop engine for the given configuration.
    ///
    /// - Parameter configuration: The goal, stop condition, and safety caps the
    ///   engine should run with.
    /// - Returns: A fresh, idle ``RegattaLoopEngine``.
    func makeEngine(for configuration: RegattaLoopConfiguration) -> RegattaLoopEngine
}

/// A ``RegattaLoopEngineProviding`` built from a closure.
///
/// Convenient at the composition root where the worker is captured from the
/// surrounding orchestration:
///
/// ```swift
/// let provider = RegattaLoopEngineProvider { config in
///     RegattaLoopEngine(configuration: config, worker: myWorker)
/// }
/// ```
public struct RegattaLoopEngineProvider: RegattaLoopEngineProviding {
    private let build: @Sendable (RegattaLoopConfiguration) -> RegattaLoopEngine

    /// Creates a closure-backed provider.
    ///
    /// - Parameter build: Builds an engine for a configuration. Capture the
    ///   worker (and any condition) here.
    public init(build: @escaping @Sendable (RegattaLoopConfiguration) -> RegattaLoopEngine) {
        self.build = build
    }

    public func makeEngine(for configuration: RegattaLoopConfiguration) -> RegattaLoopEngine {
        build(configuration)
    }
}
