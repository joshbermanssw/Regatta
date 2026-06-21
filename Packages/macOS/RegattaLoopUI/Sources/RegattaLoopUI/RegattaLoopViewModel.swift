public import Foundation
import Observation
public import RegattaCore

/// The `@MainActor @Observable` view model that drives the Regatta loop view.
///
/// It owns the loop lifecycle: it builds a ``RegattaLoopEngine`` from the current
/// ``RegattaLoopConfiguration`` (via an injected ``RegattaLoopEngineProviding``),
/// runs it, and consumes the engine's `stateStream()` to project value-typed
/// snapshots — ``phase``, ``configuration``, ``iterations``, ``totalTokensUsed``,
/// ``stopReason`` — that SwiftUI reads directly.
///
/// ## Respecting the snapshot boundary
/// The history list reads ``iterations`` (an array of ``RegattaLoopIterationRow``
/// value snapshots) at the view level and passes copies into rows. No row holds
/// the engine actor or this view model — the engine reference lives only in
/// `@ObservationIgnored` private state and is touched solely through `await`
/// inside owned `Task`s.
///
/// ## Pause / edit against an immutable engine
/// The engine has no pause or edit API and must not be modified (issue #19). So:
/// - **Pause** requests the engine stop at the next iteration boundary
///   (`requestManualStop()`), but the view model records the intent as
///   ``RegattaLoopRunPhase/paused`` (not finished) so the run can resume.
/// - **Resume** builds a *fresh* engine from the preserved configuration and runs
///   it; completed history from prior segments is retained across the resume.
/// - **Edit** is only allowed while idle / paused / finished; committing rebuilds
///   the engine from the new configuration.
///
/// ## Jump into terminal (#16/#17 seam)
/// Human takeover is delegated to ``RegattaLoopTerminalJumping``. Until the
/// worker-pane plumbing (issues #16/#17) lands, an injected
/// ``RegattaLoopTerminalJumpUnavailable`` reports the action as disabled.
@MainActor
@Observable
public final class RegattaLoopViewModel {

    // MARK: - Observable state (read by SwiftUI)

    /// The current configuration (goal, stop condition, safety caps).
    public private(set) var configuration: RegattaLoopConfiguration

    /// The loop view's lifecycle phase, layered on the engine status.
    public private(set) var phase: RegattaLoopRunPhase = .idle

    /// The iteration history as value-snapshot rows, in iteration order.
    public private(set) var iterations: [RegattaLoopIterationRow] = []

    /// Total tokens consumed across the retained history.
    public private(set) var totalTokensUsed: Int = 0

    /// The reason the loop finished, when ``phase`` is `.finished`.
    public private(set) var stopReason: RegattaLoopStopReason?

    /// The failure summary, when the loop finished by failing.
    public private(set) var failureSummary: String?

    /// The identifier of the worker this loop belongs to, used for terminal jump.
    public let workerID: String

    // MARK: - Non-observable dependencies / state

    @ObservationIgnored
    private let engineProvider: any RegattaLoopEngineProviding

    @ObservationIgnored
    private let terminalJumper: any RegattaLoopTerminalJumping

    /// The currently running engine for this segment, if any.
    @ObservationIgnored
    private var engine: RegattaLoopEngine?

    /// The task consuming the engine `stateStream()`.
    @ObservationIgnored
    private var streamTask: Task<Void, Never>?

    /// The task running the engine to completion.
    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    /// History accumulated from already-finished segments, prepended to the live
    /// segment's history so pause/resume preserves the full timeline. Iterations
    /// in resumed segments are re-indexed so the row ids stay unique.
    @ObservationIgnored
    private var retainedHistory: [RegattaLoopIterationRow] = []

    /// `true` while a pause was requested for the current segment so the stream's
    /// terminal snapshot is interpreted as paused rather than finished.
    @ObservationIgnored
    private var pauseRequested = false

    // MARK: - Init

    /// Creates a loop view model.
    ///
    /// - Parameters:
    ///   - configuration: The initial loop configuration.
    ///   - workerID: The owning worker's identifier (for terminal jump).
    ///   - engineProvider: Builds engines from configurations. Inject a fake in
    ///     tests; at the app composition root capture the real worker.
    ///   - terminalJumper: The human-takeover seam. Defaults to the unavailable
    ///     stub until #16/#17 land.
    public init(
        configuration: RegattaLoopConfiguration,
        workerID: String,
        engineProvider: any RegattaLoopEngineProviding,
        terminalJumper: any RegattaLoopTerminalJumping = RegattaLoopTerminalJumpUnavailable()
    ) {
        self.configuration = configuration
        self.workerID = workerID
        self.engineProvider = engineProvider
        self.terminalJumper = terminalJumper
    }

    // MARK: - Derived UI state

    /// Whether the "jump into terminal" control is enabled.
    public var canJumpIntoTerminal: Bool {
        terminalJumper.canJumpIntoTerminal
    }

    /// Whether the goal / condition / caps can be edited right now.
    ///
    /// Editing a live run is disallowed; pause or stop first.
    public var canEdit: Bool {
        switch phase {
        case .idle, .paused, .editing, .finished:
            return true
        case .running:
            return false
        }
    }

    // MARK: - Control intents

    /// Starts the loop (or resumes a paused one) using the current configuration.
    ///
    /// No-op while already running or editing.
    public func start() {
        guard phase.canStart else { return }
        launchEngine(with: configuration)
    }

    /// Requests the running loop pause at the next iteration boundary.
    ///
    /// The in-flight iteration finishes and is recorded; the run then settles
    /// into ``RegattaLoopRunPhase/paused`` so it can be resumed.
    public func pause() {
        guard case .running = phase, let engine else { return }
        pauseRequested = true
        Task { await engine.requestManualStop() }
    }

    /// Resumes a paused loop by launching a fresh engine over the retained
    /// history.
    public func resume() {
        guard case .paused = phase else { return }
        launchEngine(with: configuration)
    }

    /// Stops the loop permanently at the next iteration boundary.
    ///
    /// Unlike ``pause()``, the resulting terminal state is treated as finished.
    public func stop() {
        guard case .running = phase, let engine else { return }
        pauseRequested = false
        Task { await engine.requestManualStop() }
    }

    /// Enters edit mode so the goal / condition / caps can be changed.
    ///
    /// Allowed only when not actively running. While editing, ``start()`` is
    /// gated until ``commitEdit(_:)`` or ``cancelEdit()``.
    public func beginEdit() {
        guard canEdit else { return }
        phase = .editing
    }

    /// Commits an edited configuration and leaves edit mode.
    ///
    /// - Parameter configuration: The new configuration to adopt. The loop does
    ///   not auto-start; call ``start()`` to run with the new settings.
    public func commitEdit(_ configuration: RegattaLoopConfiguration) {
        self.configuration = configuration
        // Returning to idle (fresh edit before any run) vs. paused (edit between
        // segments) is decided by whether any history exists.
        phase = iterations.isEmpty ? .idle : .paused
    }

    /// Cancels edit mode without changing the configuration.
    public func cancelEdit() {
        guard case .editing = phase else { return }
        phase = iterations.isEmpty ? .idle : .paused
    }

    /// Asks the injected ``RegattaLoopTerminalJumping`` to focus the worker's
    /// terminal for human takeover.
    ///
    /// No-op when ``canJumpIntoTerminal`` is `false` (e.g. the #16/#17 seam is
    /// still stubbed).
    public func jumpIntoTerminal() {
        guard terminalJumper.canJumpIntoTerminal else { return }
        terminalJumper.jumpIntoTerminal(workerID: workerID)
    }

    /// Cancels in-flight tasks and detaches the engine. Idempotent.
    public func shutdown() {
        streamTask?.cancel()
        runTask?.cancel()
        streamTask = nil
        runTask = nil
        engine = nil
    }

    // MARK: - Engine lifecycle

    /// Builds and runs an engine for `config`, wiring its stream into this model.
    private func launchEngine(with config: RegattaLoopConfiguration) {
        // Fold any previously displayed live history into the retained baseline so
        // the resumed segment is appended, not replaced.
        retainedHistory = iterations
        pauseRequested = false

        let newEngine = engineProvider.makeEngine(for: config)
        engine = newEngine
        phase = .running
        stopReason = nil
        failureSummary = nil

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            let stream = await newEngine.stateStream()
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                self?.apply(snapshot)
            }
        }

        runTask?.cancel()
        runTask = Task { await newEngine.run() }
    }

    /// Projects a fresh engine snapshot into observable state.
    private func apply(_ snapshot: RegattaLoopState) {
        // Re-index the live segment's rows so they sit after the retained ones.
        let base = retainedHistory.count
        let liveRows = snapshot.history.enumerated().map { offset, record in
            RegattaLoopIterationRow(
                index: base + offset,
                kind: record.outcome.kind,
                summary: record.summary,
                duration: record.duration,
                tokensUsed: record.tokensUsed
            )
        }
        iterations = retainedHistory + liveRows
        totalTokensUsed = iterations.reduce(0) { $0 + $1.tokensUsed }

        switch snapshot.status {
        case .idle:
            // Pre-run snapshot; keep whatever phase the intent set.
            break
        case .running:
            phase = .running
        case .stopped(let reason):
            // A user-requested pause manifests as a manualStop terminal status;
            // interpret it as paused rather than finished when pause was asked.
            if pauseRequested, reason == .manualStop {
                phase = .paused
                stopReason = nil
            } else {
                phase = .finished(snapshot.status)
                stopReason = reason
            }
        case .failed(let summary):
            phase = .finished(snapshot.status)
            failureSummary = summary
        }
    }
}
