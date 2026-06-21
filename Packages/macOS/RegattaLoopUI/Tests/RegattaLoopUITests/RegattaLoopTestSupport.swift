import Foundation
import RegattaCore
@testable import RegattaLoopUI

/// A configurable terminal-jump seam for tests: records calls and reports a
/// caller-controlled `canJumpIntoTerminal`.
@MainActor
final class FakeTerminalJumper: RegattaLoopTerminalJumping {
    var canJumpIntoTerminal: Bool
    private(set) var jumpedWorkerIDs: [String] = []

    init(canJump: Bool) {
        self.canJumpIntoTerminal = canJump
    }

    func jumpIntoTerminal(workerID: String) {
        jumpedWorkerIDs.append(workerID)
    }
}

/// An engine provider that builds engines wrapping a fixed worker, capturing the
/// configurations it was asked to build so tests can assert edit/resume rebuilds.
struct FakeEngineProvider: RegattaLoopEngineProviding {
    let worker: any RegattaLoopWorker

    init(worker: any RegattaLoopWorker) {
        self.worker = worker
    }

    func makeEngine(for configuration: RegattaLoopConfiguration) -> RegattaLoopEngine {
        RegattaLoopEngine(configuration: configuration, worker: worker)
    }
}

extension RegattaLoopViewModel {
    /// Bounded, sleep-free wait until `predicate` holds (or the cap is reached),
    /// driving the run loop forward by yielding the main actor between checks.
    /// Returns `true` if the predicate became satisfied.
    func waitUntil(
        _ predicate: @MainActor (RegattaLoopViewModel) -> Bool,
        maxYields: Int = 5_000
    ) async -> Bool {
        var yields = 0
        while yields < maxYields {
            if predicate(self) { return true }
            await Task.yield()
            yields += 1
        }
        return predicate(self)
    }
}
