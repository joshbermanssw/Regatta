public import RegattaGitHub
import Foundation

/// The Regatta Fleet: the registry of long-lived PR shepherd watchers.
///
/// The Fleet owns one ``ShepherdWatcher`` per pull request, keyed by
/// ``PullRequestRef`` identity. Handing the same PR off twice is **idempotent**:
/// the second ``handoff(_:)`` returns the existing shepherd's current state and
/// does not create a duplicate watcher.
///
/// Observers subscribe via ``snapshots()``, an `AsyncStream` of the full
/// shepherd list. A new aggregate snapshot is emitted whenever any shepherd
/// polls or when a shepherd is added or removed.
///
/// ## Wiring note (#16)
/// The Fleet currently owns only shepherds. When the orchestrator (#16) lands
/// its ephemeral-worker entity model, workers join the same Fleet so the UI can
/// render both kinds; the ``FleetEntry`` seam already distinguishes them by
/// ``FleetEntryKind``.
///
/// ## Concurrency
/// `actor` — all mutable state is isolated. The injected `makeWatcher` factory
/// lets tests supply watchers backed by a fake poller. The shared production
/// ``PullRequestPolling`` is reused across watchers.
public actor Fleet {
    private let makeWatcher: @Sendable (PullRequestRef) -> ShepherdWatcher
    private let autoStart: Bool

    /// The per-PR autonomy safety gate (#32). All outward-facing actions are
    /// submitted here; it executes them immediately (`.auto`) or holds them for
    /// approval (`.staged`). The Fleet overlays each shepherd's current mode onto
    /// the snapshots it emits so the UI can render the toggle.
    public let autonomyGate: AutonomyGate

    private var watchers: [String: ShepherdWatcher] = [:]
    private var latest: [String: ShepherdState] = [:]
    private var fanoutTasks: [String: Task<Void, Never>] = [:]

    /// A synchronous mirror of each PR's autonomy mode, kept in lockstep with
    /// ``autonomyGate`` (the source of truth). Lets ``currentSnapshots()`` overlay
    /// the mode without an `await` into the gate actor. Missing key ⇒ staged.
    private var modes: [String: AutonomyMode] = [:]

    private var continuations: [UUID: AsyncStream<[ShepherdState]>.Continuation] = [:]

    /// Creates a Fleet with an explicit watcher factory.
    ///
    /// - Parameters:
    ///   - autoStart: Whether each new watcher's poll loop should start
    ///     immediately on handoff. Defaults to `true`. Tests pass `false` and
    ///     drive polls manually via the watcher returned from ``handoff(_:)``.
    ///   - autonomyGate: The shared autonomy safety gate (#32). Defaults to a
    ///     gate with the staged default and a no-op executor; #30/#31 inject a
    ///     gate with a real push/reply/resolve executor.
    ///   - makeWatcher: Builds a ``ShepherdWatcher`` for a given PR reference.
    public init(
        autoStart: Bool = true,
        autonomyGate: AutonomyGate = AutonomyGate(),
        makeWatcher: @escaping @Sendable (PullRequestRef) -> ShepherdWatcher
    ) {
        self.autoStart = autoStart
        self.autonomyGate = autonomyGate
        self.makeWatcher = makeWatcher
    }

    /// Creates a production Fleet whose watchers share one ``PullRequestPolling``.
    ///
    /// - Parameters:
    ///   - poller: The shared polling seam (defaults to a real ``GitHubPoller``).
    ///   - pollInterval: The interval passed to every watcher. Defaults to 30s.
    public init(
        poller: any PullRequestPolling = GitHubPoller(),
        pollInterval: Duration = .seconds(30),
        autonomyGate: AutonomyGate = AutonomyGate()
    ) {
        self.autoStart = true
        self.autonomyGate = autonomyGate
        self.makeWatcher = { ref in
            ShepherdWatcher(pullRequest: ref, poller: poller, pollInterval: pollInterval)
        }
    }

    /// Hands a pull request off to the Fleet, creating a persistent shepherd if
    /// one does not already exist for that PR.
    ///
    /// Idempotent on ``PullRequestRef`` identity: a repeat handoff of the same PR
    /// returns the existing shepherd and does not create a duplicate.
    ///
    /// - Parameter pullRequest: The PR to shepherd.
    /// - Returns: The shepherd's ``ShepherdWatcher`` (existing or newly created).
    @discardableResult
    public func handoff(_ pullRequest: PullRequestRef) -> ShepherdWatcher {
        if let existing = watchers[pullRequest.id] {
            return existing
        }
        let watcher = makeWatcher(pullRequest)
        watchers[pullRequest.id] = watcher
        latest[pullRequest.id] = ShepherdState(pullRequest: pullRequest, phase: .starting)

        // Fan the watcher's per-PR stream into the aggregate snapshot stream.
        fanoutTasks[pullRequest.id] = Task { [weak self] in
            let stream = await watcher.states()
            for await state in stream {
                await self?.absorb(state)
            }
        }

        if autoStart {
            Task { await watcher.start() }
        }

        emit()
        return watcher
    }

    /// Whether a shepherd already exists for the given PR.
    public func contains(_ pullRequest: PullRequestRef) -> Bool {
        watchers[pullRequest.id] != nil
    }

    /// The current list of shepherd snapshots, ordered by PR identity for stable
    /// rendering. Each snapshot carries the PR's current ``AutonomyMode`` overlaid
    /// from the Fleet's mode mirror.
    public func currentSnapshots() -> [ShepherdState] {
        latest.values
            .map { overlayMode($0) }
            .sorted { $0.id < $1.id }
    }

    /// The current autonomy mode for a PR (staged unless explicitly changed).
    public func autonomyMode(for pullRequest: PullRequestRef) -> AutonomyMode {
        modes[pullRequest.id] ?? .staged
    }

    /// Sets a PR's autonomy mode. Changeable at any time. Updates both the gate
    /// (source of truth) and the Fleet's synchronous mirror, then re-emits so the
    /// UI reflects the new mode.
    public func setAutonomyMode(_ mode: AutonomyMode, for pullRequest: PullRequestRef) async {
        modes[pullRequest.id] = mode
        await autonomyGate.setMode(mode, for: pullRequest)
        emit()
    }

    /// Removes (and stops) the shepherd for a PR, if present.
    public func dismiss(_ pullRequest: PullRequestRef) async {
        guard let watcher = watchers[pullRequest.id] else { return }
        fanoutTasks[pullRequest.id]?.cancel()
        fanoutTasks[pullRequest.id] = nil
        await watcher.stop()
        watchers[pullRequest.id] = nil
        latest[pullRequest.id] = nil
        modes[pullRequest.id] = nil
        emit()
    }

    /// Returns an `AsyncStream` of the full shepherd list. Replays the current
    /// snapshot immediately, then a new array after each shepherd change.
    public func snapshots() -> AsyncStream<[ShepherdState]> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.yield(currentSnapshots())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token) }
            }
        }
    }

    // MARK: - Private

    private func absorb(_ state: ShepherdState) {
        latest[state.id] = state
        emit()
    }

    /// Returns the state with the PR's current autonomy mode applied. The watcher
    /// is mode-agnostic and always publishes the staged default; the Fleet is the
    /// authority for the mode, so it overlays it here.
    private func overlayMode(_ state: ShepherdState) -> ShepherdState {
        let mode = modes[state.id] ?? .staged
        guard state.autonomyMode != mode else { return state }
        return ShepherdState(
            pullRequest: state.pullRequest,
            phase: state.phase,
            checks: state.checks,
            reviewThreads: state.reviewThreads,
            autonomyMode: mode,
            needsAttention: state.needsAttention
        )
    }

    private func emit() {
        let snapshot = currentSnapshots()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ token: UUID) {
        continuations[token] = nil
    }
}
