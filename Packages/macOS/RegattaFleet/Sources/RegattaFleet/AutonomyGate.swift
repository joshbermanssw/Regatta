public import Foundation

/// The outcome of submitting an action to the ``AutonomyGate``.
public enum SubmitResult: Sendable, Equatable {
    /// The action ran immediately (``AutonomyMode/auto`` mode) and completed.
    case executed(PendingAction)
    /// The action failed to execute immediately (``AutonomyMode/auto`` mode).
    case executionFailed(PendingAction)
    /// The action was enqueued for approval (``AutonomyMode/staged`` mode).
    case enqueued(PendingAction)
}

/// The per-PR safety gate that every outward-facing shepherd action passes
/// through (issue #32).
///
/// The gate is the single chokepoint between "the shepherd wants to do X" and
/// "X actually happens on GitHub". For each pull request it holds an
/// ``AutonomyMode`` (default ``AutonomyMode/staged``) and decides, per
/// submission, whether to:
///
/// - **execute immediately** (``AutonomyMode/auto``), running the action through
///   the injected ``ActionExecuting`` seam, or
/// - **enqueue it as pending** (``AutonomyMode/staged``), holding it until the
///   user calls ``approve(_:)`` or ``reject(_:)``.
///
/// All execution goes through ``ActionExecuting``, so #30/#31 plug in their real
/// push/reply/resolve logic without touching the gate. Issue #32 ships only the
/// policy.
///
/// ## Per-PR isolation
/// Modes and queues are keyed by ``PullRequestRef/id``. Flipping one PR to
/// ``AutonomyMode/auto`` never affects another PR's staged queue.
///
/// ## Observation
/// ``pendingActions()`` returns an `AsyncStream` of the full pending-action list
/// (value snapshots), replayed on subscribe and re-emitted on every change. The
/// view layer consumes this directly — no actor reference escapes into a
/// `ForEach` (snapshot-boundary rule).
///
/// ## Concurrency
/// `actor` — all mutable state (modes, queue, continuations) is isolated.
public actor AutonomyGate {
    private let executor: any ActionExecuting

    /// Per-PR autonomy mode, keyed by ``PullRequestRef/id``. Missing key ⇒
    /// ``defaultMode`` (staged).
    private var modes: [String: AutonomyMode] = [:]

    /// The default mode for a PR with no explicit mode set. New handoffs inherit
    /// this; it is ``AutonomyMode/staged`` per the #32 safety policy.
    private let defaultMode: AutonomyMode

    /// Pending (and recently-resolved) actions, ordered by submission for stable
    /// rendering. Only ``ActionStatus/pending`` actions are awaiting a decision;
    /// completed/rejected/failed entries are dropped from the queue immediately
    /// after they resolve (the stream observers see the transition via the
    /// `SubmitResult`/return value, not via lingering rows).
    private var pending: [UUID: PendingAction] = [:]
    private var order: [UUID] = []

    private var continuations: [UUID: AsyncStream<[PendingAction]>.Continuation] = [:]

    /// Creates an autonomy gate.
    ///
    /// - Parameters:
    ///   - executor: The execution seam (#30/#31 supply real ones; defaults to
    ///     ``NoopActionExecutor`` so the policy is testable with no network).
    ///   - defaultMode: The mode applied to PRs with no explicit mode. Defaults
    ///     to ``AutonomyMode/staged`` (the #32 safety default). Overridable only
    ///     for tests; production must keep the staged default.
    public init(
        executor: any ActionExecuting = NoopActionExecutor(),
        defaultMode: AutonomyMode = .staged
    ) {
        self.executor = executor
        self.defaultMode = defaultMode
    }

    // MARK: - Mode

    /// The current autonomy mode for a PR (``defaultMode`` if never set).
    public func mode(for pullRequest: PullRequestRef) -> AutonomyMode {
        modes[pullRequest.id] ?? defaultMode
    }

    /// Sets the autonomy mode for a PR. Changeable at any time.
    ///
    /// Switching a PR to ``AutonomyMode/auto`` does **not** auto-drain its
    /// already-pending actions: those were queued under the staged policy and
    /// still require an explicit ``approve(_:)`` (the user can also
    /// ``reject(_:)`` them). Only *future* submissions execute immediately. This
    /// avoids a surprise burst of side effects the instant the toggle flips.
    public func setMode(_ mode: AutonomyMode, for pullRequest: PullRequestRef) {
        modes[pullRequest.id] = mode
    }

    // MARK: - Submit

    /// Submits an outward-facing action to the gate.
    ///
    /// - In ``AutonomyMode/auto``: executes immediately via the executor and
    ///   returns ``SubmitResult/executed(_:)`` (or
    ///   ``SubmitResult/executionFailed(_:)`` on throw).
    /// - In ``AutonomyMode/staged``: enqueues the action as
    ///   ``ActionStatus/pending`` and returns ``SubmitResult/enqueued(_:)``.
    ///
    /// - Parameter action: The action to gate. Its
    ///   ``PendingAction/pullRequest`` selects the mode and queue.
    /// - Returns: A ``SubmitResult`` describing what happened.
    @discardableResult
    public func submit(_ action: PendingAction) async -> SubmitResult {
        switch mode(for: action.pullRequest) {
        case .auto:
            return await runImmediately(action)
        case .staged:
            enqueue(action)
            return .enqueued(action)
        }
    }

    // MARK: - Approve / Reject

    /// Approves a pending action: executes it through the executor and removes it
    /// from the queue.
    ///
    /// - Parameter id: The ``PendingAction/id`` to approve.
    /// - Returns: The resolved action (``ActionStatus/completed`` or
    ///   ``ActionStatus/failed``), or `nil` if no pending action has that id.
    @discardableResult
    public func approve(_ id: UUID) async -> PendingAction? {
        guard let action = pending[id], action.status == .pending else { return nil }
        // Mark executing and let observers see the transient state.
        update(action.withStatus(.executing))
        let resolved: PendingAction
        do {
            try await executor.execute(action)
            resolved = action.withStatus(.completed)
        } catch {
            resolved = action.withStatus(.failed)
        }
        remove(id)
        return resolved
    }

    /// Rejects a pending action: drops it from the queue without executing.
    ///
    /// - Parameter id: The ``PendingAction/id`` to reject.
    /// - Returns: The rejected action (``ActionStatus/rejected``), or `nil` if no
    ///   pending action has that id.
    @discardableResult
    public func reject(_ id: UUID) -> PendingAction? {
        guard let action = pending[id], action.status == .pending else { return nil }
        remove(id)
        return action.withStatus(.rejected)
    }

    // MARK: - Reads

    /// All currently pending actions, oldest first.
    public func currentPending() -> [PendingAction] {
        order.compactMap { pending[$0] }
    }

    /// Pending actions for one PR only, oldest first.
    public func currentPending(for pullRequest: PullRequestRef) -> [PendingAction] {
        currentPending().filter { $0.pullRequest.id == pullRequest.id }
    }

    /// An `AsyncStream` of the full pending-action list. Replays the current
    /// snapshot on subscribe, then re-emits after every change.
    public func pendingActions() -> AsyncStream<[PendingAction]> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.yield(currentPending())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token) }
            }
        }
    }

    // MARK: - Private

    private func runImmediately(_ action: PendingAction) async -> SubmitResult {
        do {
            try await executor.execute(action)
            return .executed(action.withStatus(.completed))
        } catch {
            return .executionFailed(action.withStatus(.failed))
        }
    }

    private func enqueue(_ action: PendingAction) {
        pending[action.id] = action.withStatus(.pending)
        order.append(action.id)
        emit()
    }

    private func update(_ action: PendingAction) {
        guard pending[action.id] != nil else { return }
        pending[action.id] = action
        emit()
    }

    private func remove(_ id: UUID) {
        guard pending[id] != nil else { return }
        pending[id] = nil
        order.removeAll { $0 == id }
        emit()
    }

    private func emit() {
        let snapshot = currentPending()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ token: UUID) {
        continuations[token] = nil
    }
}
