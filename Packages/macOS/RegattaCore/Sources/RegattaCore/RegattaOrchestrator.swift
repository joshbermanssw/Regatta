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
/// ## Concurrency
/// An `actor` owns all mutable worker state. The ``PaneBridge`` and
/// ``RegattaWorktreeManager`` dependencies are injected, so tests drive the full
/// spawn lifecycle headlessly with a fake bridge (`fake-agent.sh`) and a temp-dir
/// worktree manager.
public actor RegattaOrchestrator {

    // MARK: - Worker record (internal mutable state)

    /// Internal bookkeeping for one tracked worker.
    private struct WorkerRecord {
        var worker: Worker
        /// The pane handle ID once the agent process is spawned; `nil` while queued.
        var paneID: PaneHandle.ID?
        /// The task observing the worker's output stream, cancelled on shutdown.
        var observeTask: Task<Void, Never>?
    }

    // MARK: - State

    private var records: [UUID: WorkerRecord] = [:]
    /// Preserves Fleet ordering (most-recently-spawned last).
    private var order: [UUID] = []
    private var continuations: [UUID: AsyncStream<[Worker]>.Continuation] = [:]

    // MARK: - Dependencies

    private let worktreeManager: RegattaWorktreeManager
    private let paneBridge: any PaneBridge

    // MARK: - Init

    /// Creates an orchestrator.
    ///
    /// - Parameters:
    ///   - worktreeManager: Provisions isolated worktrees for each worker.
    ///   - paneBridge: Launches and observes the agent process for each worker.
    public init(
        worktreeManager: RegattaWorktreeManager,
        paneBridge: any PaneBridge
    ) {
        self.worktreeManager = worktreeManager
        self.paneBridge = paneBridge
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
    /// ``WorkerStatus/queued``; the worktree provisioning and agent launch happen
    /// on a detached task that drives the worker to ``WorkerStatus/running`` and
    /// then to a terminal status.
    ///
    /// - Parameter spec: The brain's request describing the worker.
    /// - Returns: The new worker's stable ID, usable with ``cancelWorker(_:)``.
    @discardableResult
    public func spawnWorker(_ spec: WorkerSpec) -> UUID {
        let id = UUID()
        let worker = Worker(
            id: id,
            name: spec.name,
            prompt: spec.prompt,
            status: .queued,
            providerID: spec.providerID
        )
        records[id] = WorkerRecord(worker: worker, paneID: nil, observeTask: nil)
        order.append(id)
        broadcast()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runWorker(id: id, spec: spec)
        }
        records[id]?.observeTask = task
        return id
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
            updateStatus(id: id, to: .failed(String(describing: error)))
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

        // 3. Drive status from the process lifecycle.
        var exitCode: Int32?
        for await event in handle.output {
            if Task.isCancelled { return }
            if case .terminated(let code) = event {
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

    private func updateStatus(id: UUID, to status: WorkerStatus) {
        guard var record = records[id] else { return }
        record.worker = record.worker.withStatus(status)
        records[id] = record
        broadcast()
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
