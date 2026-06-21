import Foundation
@testable import RegattaCore

/// A headless ``PaneBridge`` test double for driving the orchestrator's spawn
/// lifecycle without a real process or Ghostty pane.
///
/// Each spawn produces a handle whose `output` stream is fed by a controllable
/// emitter, so a test can deterministically drive a worker from `.running` to a
/// terminal status, or hold it open to assert cancellation. The bridge records
/// the specs it was asked to spawn and the IDs it was asked to terminate.
///
/// Two spawn modes are supported:
/// - `autoExit(code:)` — emit a `.terminated(code)` immediately so the worker
///   reaches a terminal status on its own (deterministic, no real time).
/// - `controlled` — keep the stream open; the test drives it via the returned
///   ``Controller`` (emit output, then terminate) to model a long-running agent.
actor FakePaneBridge: PaneBridge {

    /// How a given spawn should behave.
    enum Behavior: Sendable {
        /// Immediately terminate with `code` (worker reaches terminal status).
        case autoExit(Int32)
        /// Stay alive until the test terminates it or drives the controller.
        case controlled
        /// Fail to spawn with the given message.
        case spawnFailure(String)
    }

    /// Lets a test drive a controlled handle's stream after spawn.
    final class Controller: @unchecked Sendable {
        let continuation: AsyncStream<PaneOutputEvent>.Continuation
        init(_ continuation: AsyncStream<PaneOutputEvent>.Continuation) {
            self.continuation = continuation
        }
        func emit(_ event: PaneOutputEvent) { continuation.yield(event) }
        func finish(terminated code: Int32) {
            continuation.yield(.terminated(code))
            continuation.finish()
        }
    }

    private let behavior: Behavior
    private var running: Set<PaneHandle.ID> = []
    private var controllers: [PaneHandle.ID: AsyncStream<PaneOutputEvent>.Continuation] = [:]

    /// All specs passed to ``spawn(_:)`` in order.
    private(set) var spawnedSpecs: [PaneSpec] = []
    /// All IDs passed to ``terminate(_:)`` in order.
    private(set) var terminatedIDs: [PaneHandle.ID] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func spawn(_ spec: PaneSpec) async throws -> PaneHandle {
        spawnedSpecs.append(spec)

        if case .spawnFailure(let message) = behavior {
            throw PaneBridgeError.spawnFailed(message)
        }

        let id = PaneHandle.ID()
        var capturedContinuation: AsyncStream<PaneOutputEvent>.Continuation!
        let stream = AsyncStream<PaneOutputEvent> { continuation in
            capturedContinuation = continuation
        }
        running.insert(id)

        switch behavior {
        case .autoExit(let code):
            capturedContinuation.yield(.stdout("started"))
            capturedContinuation.yield(.terminated(code))
            capturedContinuation.finish()
            running.remove(id)
        case .controlled:
            controllers[id] = capturedContinuation
            capturedContinuation.yield(.stdout("started"))
        case .spawnFailure:
            break // unreachable, handled above
        }

        return PaneHandle(id: id, output: stream)
    }

    func terminate(_ id: PaneHandle.ID) async throws {
        terminatedIDs.append(id)
        guard running.contains(id) else {
            throw PaneBridgeError.unknownHandle(id)
        }
        running.remove(id)
        if let continuation = controllers.removeValue(forKey: id) {
            continuation.yield(.terminated(-15))
            continuation.finish()
        }
    }

    func isRunning(_ id: PaneHandle.ID) async -> Bool {
        running.contains(id)
    }

    /// Returns the controller for a previously spawned controlled handle.
    func controller(for id: PaneHandle.ID) -> Controller? {
        controllers[id].map(Controller.init)
    }
}
