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

/// A worker whose iterations are paced by the test, removing the race between a
/// fast free-running loop and a control intent (pause/stop) arriving too late.
///
/// Each call to ``runIteration(index:goal:)`` reports that it has *entered* the
/// iteration (so the test knows the loop is provably mid-run) and then suspends
/// until the test hands it a release token. This lets a test:
///
/// 1. `await waitForIterationStart()` — the loop is now blocked inside an
///    iteration, with the engine not yet able to advance toward any cap.
/// 2. request `pause()` / `stop()` on the view model while the worker is blocked.
/// 3. `release()` the blocked iteration so it completes and the engine observes
///    the manual-stop request at the top of the next turn.
///
/// Because the worker only advances one iteration per release token, the loop can
/// never sprint to the safety cap during the controlled window — the previously
/// flaky timing dependency is gone.
actor GatedLoopWorker: RegattaLoopWorker {
    private let tokens: Int

    // Iterations that have entered and are waiting for a release token.
    private var pendingEntries: [CheckedContinuation<Void, Never>] = []
    // Release tokens granted before an iteration arrived to consume them.
    private var availableReleases = 0
    // Continuations from tests awaiting the next iteration entry.
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    // Number of iterations that have entered so far.
    private var enteredCount = 0

    init(tokens: Int = 5) {
        self.tokens = tokens
    }

    func runIteration(index: Int, goal: String) async -> RegattaLoopOutcome {
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            enteredCount += 1
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if availableReleases > 0 {
                // A release token was granted ahead of this entry; consume it
                // and proceed immediately.
                availableReleases -= 1
                entered.resume()
            } else {
                pendingEntries.append(entered)
            }
        }
        return RegattaLoopOutcome(kind: .progressed, summary: "iter \(index)", tokensUsed: tokens)
    }

    /// Suspends until at least `count` iterations have entered the worker. This is
    /// signal-driven (no sleeps): each iteration entry wakes the waiters.
    func waitForIterationStart(count: Int = 1) async {
        while enteredCount < count {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                if enteredCount >= count {
                    waiter.resume()
                } else {
                    entryWaiters.append(waiter)
                }
            }
        }
    }

    /// Releases one blocked iteration (or pre-grants a token if none is blocked
    /// yet) so the loop can complete that iteration and advance one turn.
    func release() {
        if pendingEntries.isEmpty {
            availableReleases += 1
        } else {
            pendingEntries.removeFirst().resume()
        }
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
