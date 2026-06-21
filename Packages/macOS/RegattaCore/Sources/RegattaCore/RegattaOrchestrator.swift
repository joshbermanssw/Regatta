public import Foundation

/// Spawns brain-requested workers into the Fleet and tracks their live status.
///
/// This is the Orchestrator (issue #16). Given a ``WorkerSpec`` from the brain it:
/// 1. registers the worker as ``WorkerStatus/queued`` and returns its ID at once,
/// 2. provisions an isolated git worktree via ``RegattaWorktreeManager`` (#15),
/// 3. launches the agent process in that worktree via a ``PaneBridge`` (#14),
/// 4. drives the worker's status from the process lifecycle
///    (`.running` → `.done`/`.failed`), and
/// 5. lets the Fleet cancel a worker, terminating the process and cleaning up.
///
/// ## Observation
/// Every status change yields a fresh snapshot array on the stream returned by
/// ``updates()``. The Fleet view-model subscribes once and projects the snapshots
/// into value-typed ``Worker`` rows, so no actor reference crosses the SwiftUI
/// list snapshot boundary (CLAUDE.md).
///
/// ## Concurrency cap + queue (#18)
/// The orchestrator caps how many workers run at once. ``spawnWorker(_:)`` always
/// registers a worker as ``WorkerStatus/queued`` and returns immediately; a worker
/// only begins provisioning + launching when a slot is free. When a worker reaches
/// a terminal status or is cancelled, the oldest still-queued worker is promoted
/// automatically. The cap is adjustable at runtime via
/// ``setMaxConcurrentWorkers(_:)``; raising it promotes held workers right away,
/// while lowering it never terminates already-running workers — it just holds new
/// spawns until the running count falls back under the cap. All scheduling runs on
/// the actor, so promotion decisions are race-free.
///
/// ## Concurrency
/// An `actor` owns all mutable worker state. The ``PaneBridge`` and
/// ``RegattaWorktreeManager`` dependencies are injected, so tests drive the full
/// spawn lifecycle headlessly with a fake bridge (`fake-agent.sh`) and a temp-dir
/// worktree manager.
public actor RegattaOrchestrator {

    /// The fallback concurrency cap when none is supplied.
    public static let defaultMaxConcurrentWorkers = 4

    // MARK: - Worker record (internal mutable state)

    /// Internal bookkeeping for one tracked worker.
    private struct WorkerRecord {
        var worker: Worker
        /// The original spawn request, retained so a queued worker can be promoted
        /// and launched later when a run slot frees.
        let spec: WorkerSpec
        /// The pane handle ID once the agent process is spawned; `nil` while queued.
        var paneID: PaneHandle.ID?
        /// The task observing the worker's output stream, cancelled on shutdown.
        var observeTask: Task<Void, Never>?
        /// The worker's captured stdout/stderr in arrival order, retained across
        /// the run so a crashed worker's output is preserved and handed to the
        /// brain on completion (issue #35).
        var output: String = ""
        /// Whether the brain has already been notified that this worker reached a
        /// terminal status, so the notification fires exactly once.
        var notified: Bool = false
    }

    // MARK: - State

    private var records: [UUID: WorkerRecord] = [:]
    /// Preserves Fleet ordering (most-recently-spawned last).
    private var order: [UUID] = []
    private var continuations: [UUID: AsyncStream<[Worker]>.Continuation] = [:]

    /// The maximum number of workers allowed to occupy a run slot at once.
    /// Always `>= 1`; values below `1` are clamped on assignment.
    private var maxConcurrentWorkers: Int

    /// Workers that hold a run slot: promoted out of the queue and either
    /// provisioning, launching, or running. A worker leaves this set the moment it
    /// reaches a terminal status (or is cancelled), freeing its slot. Used as the
    /// authoritative "active" count for cap enforcement, independent of the brief
    /// window between promotion and the `.running` transition.
    private var slotHolders: Set<UUID> = []

    // MARK: - Dependencies

    private let worktreeManager: RegattaWorktreeManager
    private let paneBridge: any PaneBridge

    /// The brain (or test double) notified once when a worker reaches a terminal
    /// status, with the worker's retained output attached (issue #35). `nil` when
    /// no observer is wired.
    private let workerObserver: (any WorkerObserver)?

    // MARK: - Init

    /// Creates an orchestrator.
    ///
    /// - Parameters:
    ///   - worktreeManager: Provisions isolated worktrees for each worker.
    ///   - paneBridge: Launches and observes the agent process for each worker.
    ///   - maxConcurrentWorkers: The cap on simultaneously running workers; excess
    ///     spawns are held ``WorkerStatus/queued`` until a slot frees. Clamped to a
    ///     minimum of `1`. Defaults to ``defaultMaxConcurrentWorkers``.
    ///   - workerObserver: An optional sink notified once per worker when it
    ///     reaches a terminal status, with the worker's retained output (issue
    ///     #35). The brain conforms to ``WorkerObserver`` so it learns of crashes.
    public init(
        worktreeManager: RegattaWorktreeManager,
        paneBridge: any PaneBridge,
        maxConcurrentWorkers: Int = RegattaOrchestrator.defaultMaxConcurrentWorkers,
        workerObserver: (any WorkerObserver)? = nil
    ) {
        self.worktreeManager = worktreeManager
        self.paneBridge = paneBridge
        self.maxConcurrentWorkers = max(1, maxConcurrentWorkers)
        self.workerObserver = workerObserver
    }

    // MARK: - Concurrency cap

    /// Adjusts the cap on simultaneously running workers and re-evaluates the queue.
    ///
    /// Raising the cap promotes the oldest queued workers immediately until the cap
    /// or the queue is exhausted. Lowering the cap never terminates already-running
    /// workers; it simply holds new spawns (and any still-queued workers) until the
    /// active count falls back under the new cap.
    ///
    /// - Parameter newValue: The new cap. Clamped to a minimum of `1`.
    public func setMaxConcurrentWorkers(_ newValue: Int) {
        maxConcurrentWorkers = max(1, newValue)
        scheduleQueued()
    }

    /// The current cap on simultaneously running workers.
    public func currentMaxConcurrentWorkers() -> Int {
        maxConcurrentWorkers
    }

    // MARK: - Observation

    /// Returns a stream of Fleet snapshots, emitting the current snapshot
    /// immediately and a fresh snapshot on every subsequent status change.
    ///
    /// The stream finishes when the orchestrator is deinitialised. Multiple
    /// subscribers are supported; each receives its own stream.
    public func updates() -> AsyncStream<[Worker]> {
        AsyncStream { continuation in
            let key = UUID()
            continuations[key] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(key) }
            }
        }
    }

    /// Returns the current Fleet snapshot in spawn order.
    public func workers() -> [Worker] {
        snapshot()
    }

    // MARK: - Spawn

    /// Registers a worker for `spec` and begins provisioning + launching it.
    ///
    /// Returns immediately with the worker's ID while the worker is
    /// ``WorkerStatus/queued``. If a run slot is free (active count below the cap),
    /// the worker is promoted at once: worktree provisioning and agent launch happen
    /// on a detached task that drives the worker to ``WorkerStatus/running`` and then
    /// to a terminal status. Otherwise the worker stays ``WorkerStatus/queued`` until
    /// a slot frees and the scheduler promotes it.
    ///
    /// - Parameter spec: The brain's request describing the worker.
    /// - Returns: The new worker's stable ID, usable with ``cancelWorker(_:)``.
    @discardableResult
    public func spawnWorker(_ spec: WorkerSpec) -> UUID {
        registerAndSchedule(spec, id: UUID())
    }

    /// Test seam: spawns a worker with a caller-supplied id so a test can
    /// pre-provision a colliding worktree on the branch the orchestrator will
    /// derive from that id (issue #35 worktree-conflict path). Not part of the
    /// public API — `internal` so only `@testable` test code can reach it.
    @discardableResult
    func spawnWorkerForTest(_ spec: WorkerSpec, forcedID id: UUID) -> UUID {
        registerAndSchedule(spec, id: id)
    }

    /// Registers a worker record under `id` and runs the scheduler. Shared by the
    /// public spawn and the test seam.
    @discardableResult
    private func registerAndSchedule(_ spec: WorkerSpec, id: UUID) -> UUID {
        let worker = Worker(
            id: id,
            name: spec.name,
            prompt: spec.prompt,
            status: .queued,
            providerID: spec.providerID
        )
        records[id] = WorkerRecord(worker: worker, spec: spec, paneID: nil, observeTask: nil)
        order.append(id)
        broadcast()
        scheduleQueued()
        return id
    }

    // MARK: - Scheduler

    /// Promotes the oldest queued workers into free run slots until the cap is hit
    /// or no queued workers remain. Actor-serialized, so promotion decisions never
    /// race. Idempotent and safe to call after any state change (spawn, completion,
    /// cancellation, or cap adjustment).
    private func scheduleQueued() {
        for id in order {
            guard slotHolders.count < maxConcurrentWorkers else { return }
            guard let record = records[id] else { continue }
            // Only promote workers that are still queued and not already holding a
            // slot (i.e. not yet provisioning/running).
            guard record.worker.status == .queued, !slotHolders.contains(id) else { continue }
            promote(id: id, spec: record.spec)
        }
    }

    /// Claims a slot for `id` and starts its provisioning + launch task.
    private func promote(id: UUID, spec: WorkerSpec) {
        slotHolders.insert(id)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runWorker(id: id, spec: spec)
        }
        records[id]?.observeTask = task
    }

    /// Releases the run slot held by `id` (if any) and promotes the next queued
    /// worker. Called whenever a worker reaches a terminal status or is cancelled.
    private func releaseSlotAndSchedule(_ id: UUID) {
        slotHolders.remove(id)
        scheduleQueued()
    }

    // MARK: - Cancel

    /// Cancels a tracked worker, terminating its agent process if running and
    /// marking it ``WorkerStatus/cancelled``.
    ///
    /// Idempotent for already-terminal workers (they keep their terminal status).
    ///
    /// - Parameter id: The worker to cancel.
    /// - Throws: ``OrchestratorError/unknownWorker(_:)`` if no worker has `id`.
    public func cancelWorker(_ id: UUID) async throws {
        guard let record = records[id] else {
            throw OrchestratorError.unknownWorker(id)
        }

        // Stop observing first so the terminate-induced `.terminated` event can't
        // race a `.done`/`.failed` transition over `.cancelled`.
        record.observeTask?.cancel()
        records[id]?.observeTask = nil

        if let paneID = record.paneID {
            try? await paneBridge.terminate(paneID)
        }

        guard !record.worker.status.isTerminal else { return }
        updateStatus(id: id, to: .cancelled)

        // Best-effort worktree cleanup (force, since a cancelled run may be dirty).
        try? await worktreeManager.cleanup(forWorker: id.uuidString, force: true)
    }

    // MARK: - Lifecycle driver

    /// Provisions the worktree, launches the agent, and drives the worker's status
    /// from the process lifecycle. Runs on the spawn task.
    private func runWorker(id: UUID, spec: WorkerSpec) async {
        // 1. Provision an isolated worktree.
        let worktree: RegattaWorktree
        do {
            let branch = "regatta/worker-\(id.uuidString.prefix(8))"
            worktree = try await worktreeManager.createWorktree(
                forWorker: id.uuidString,
                repoURL: spec.repoURL,
                branch: String(branch)
            )
        } catch {
            // A recoverable worktree conflict (an existing worktree/branch the
            // human is expected to resolve) parks the worker as `.blocked` so no
            // work product is lost; any other provisioning error is a genuine
            // `.failed` (issue #35).
            if let worktreeError = error as? WorktreeError, worktreeError.isConflict {
                updateStatus(id: id, to: .blocked(String(describing: error)))
            } else {
                updateStatus(id: id, to: .failed(String(describing: error)))
            }
            return
        }

        guard !Task.isCancelled, records[id] != nil else { return }

        // 2. Launch the agent process in the worktree.
        var arguments = spec.agentLaunch.arguments
        if spec.agentLaunch.appendPrompt {
            arguments.append(spec.prompt)
        }
        let paneSpec = PaneSpec(
            workingDirectory: worktree.path,
            executableURL: spec.agentLaunch.executableURL,
            arguments: arguments,
            environment: spec.agentLaunch.environment
        )

        let handle: PaneHandle
        do {
            handle = try await paneBridge.spawn(paneSpec)
        } catch {
            updateStatus(id: id, to: .failed(String(describing: error)))
            try? await worktreeManager.cleanup(forWorker: id.uuidString, force: true)
            return
        }

        records[id]?.paneID = handle.id
        updateStatus(id: id, to: .running)

        // 3. Drive status from the process lifecycle, retaining output so a
        //    crashed worker's stdout/stderr is preserved for the brain (issue #35).
        var exitCode: Int32?
        for await event in handle.output {
            if Task.isCancelled { return }
            // Retain stdout/stderr in arrival order so a crashed worker's output
            // survives and reaches the brain on completion (issue #35).
            switch event {
            case .stdout(let chunk), .stderr(let chunk):
                appendOutput(chunk, to: id)
            case .terminated(let code):
                exitCode = code
            }
        }

        // If cancelled while observing, leave status to `cancelWorker`.
        guard !Task.isCancelled, let record = records[id], !record.worker.status.isTerminal else {
            return
        }

        if let exitCode, exitCode == 0 {
            updateStatus(id: id, to: .done)
        } else {
            let code = exitCode.map(String.init) ?? "unknown"
            updateStatus(
                id: id,
                to: .failed("agent exited with code \(code)")
            )
        }
    }

    // MARK: - Snapshot + broadcast

    private func snapshot() -> [Worker] {
        order.compactMap { records[$0]?.worker }
    }

    /// Appends a captured output chunk to the worker's retained output buffer.
    private func appendOutput(_ chunk: String, to id: UUID) {
        guard records[id] != nil else { return }
        records[id]?.output += chunk
    }

    private func updateStatus(id: UUID, to status: WorkerStatus) {
        guard var record = records[id] else { return }
        record.worker = record.worker.withStatus(status)
        records[id] = record
        broadcast()

        // A worker reaching a terminal status frees its run slot; promote the next
        // queued worker. This is the single promotion-on-completion/failure path,
        // shared by the lifecycle driver and cancellation.
        if status.isTerminal {
            // Notify the brain (with retained output) exactly once before the slot
            // is released, so a crash or block reaches the brain even though the
            // worker has left the active set (issue #35).
            notifyObserverIfNeeded(id)
            releaseSlotAndSchedule(id)
        }
    }

    /// Notifies the brain (if wired) exactly once that `id` reached a terminal
    /// status, attaching the worker's retained output (issue #35). Fires for every
    /// terminal status — including `.failed` (a crash) and `.blocked` — so the
    /// brain can count failed iterations and surface crashes that left the Fleet.
    private func notifyObserverIfNeeded(_ id: UUID) {
        guard let observer = workerObserver else { return }
        guard var record = records[id], !record.notified else { return }
        record.notified = true
        records[id] = record
        let completion = WorkerCompletion(
            id: id,
            name: record.worker.name,
            prompt: record.worker.prompt,
            status: record.worker.status,
            output: record.output
        )
        Task { await observer.workerDidComplete(completion) }
    }

    private func broadcast() {
        let snap = snapshot()
        for continuation in continuations.values {
            continuation.yield(snap)
        }
    }

    private func removeContinuation(_ key: UUID) {
        continuations.removeValue(forKey: key)
    }
}
