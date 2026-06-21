public import RegattaGitHub

/// The reactive layer that turns new reviewer comments into addressing work.
///
/// A `ReviewThreadReactor` observes a shepherd's successive ``ShepherdState``
/// snapshots and, each time a poll reveals a review thread it has not yet
/// handled, dispatches a ``ReviewThreadWorker`` to address that thread — push a
/// code change and/or post a reply, then resolve it (issue #31).
///
/// ## New-comment detection
/// "New comment" is detected by diffing successive `reviewThreads` polls against
/// the set of thread IDs already handled. A thread is **actionable** when it is
/// open (not resolved, not outdated) and has at least one comment. Resolved and
/// outdated threads are ignored.
///
/// ## Idempotency
/// Each thread ID is handled **once**. The reactor records a thread ID as
/// handled only when its worker reports the thread was *fully* handled; a thread
/// whose worker was suppressed by the autonomy gate (issue #32) or that failed
/// is left unrecorded so the next poll retries it. In-flight threads are also
/// tracked so two rapid polls cannot spawn two workers for the same thread.
///
/// ## Concurrency
/// `actor` — the handled / in-flight ID sets are actor-isolated. ``observe(_:)``
/// drives the reactor from a watcher's `AsyncStream`; ``react(to:)`` processes
/// one snapshot and is exposed so tests can drive exactly one diff
/// deterministically.
public actor ReviewThreadReactor {
    private let worker: ReviewThreadWorker

    /// Thread IDs that have been fully handled; never re-dispatched.
    private var handled: Set<String> = []
    /// Thread IDs with a worker currently in flight; guards against a second
    /// poll dispatching a duplicate before the first finishes.
    private var inFlight: Set<String> = []

    /// Creates a reactor that dispatches the given worker.
    ///
    /// - Parameter worker: The per-thread worker used to address each new thread.
    public init(worker: ReviewThreadWorker) {
        self.worker = worker
    }

    /// Convenience initializer that assembles the worker from its seams.
    ///
    /// - Parameters:
    ///   - spawner: The addressing-worker spawn seam (issue #16).
    ///   - writer: The GitHub write seam for replies/resolves.
    ///   - gate: The autonomy gate for outward actions (issue #32).
    ///   - log: The per-thread activity log.
    public init(
        spawner: any WorkerSpawning,
        writer: any PullRequestWriting,
        gate: any OutwardActionGate,
        log: any ReviewThreadActivityLogging
    ) {
        self.worker = ReviewThreadWorker(spawner: spawner, writer: writer, gate: gate, log: log)
    }

    /// The set of thread IDs handled so far. Exposed for tests and inspection.
    public var handledThreadIDs: Set<String> { handled }

    /// Drives the reactor from a watcher's snapshot stream until it finishes.
    ///
    /// Each yielded ``ShepherdState`` is diffed via ``react(to:)``.
    ///
    /// - Parameter states: The shepherd's `AsyncStream` of state snapshots.
    public func observe(_ states: AsyncStream<ShepherdState>) async {
        for await state in states {
            await react(to: state)
        }
    }

    /// Processes a single shepherd snapshot, dispatching workers for any newly
    /// actionable threads.
    ///
    /// Exposed so tests can feed snapshots one at a time and assert idempotency
    /// without racing a live stream.
    ///
    /// - Parameter state: The latest shepherd state.
    public func react(to state: ShepherdState) async {
        let newThreads = state.reviewThreads.filter { thread in
            Self.isActionable(thread)
                && !handled.contains(thread.id)
                && !inFlight.contains(thread.id)
        }
        guard !newThreads.isEmpty else { return }

        for thread in newThreads {
            inFlight.insert(thread.id)
            let fullyHandled = await worker.handle(thread, in: state.pullRequest)
            inFlight.remove(thread.id)
            if fullyHandled {
                handled.insert(thread.id)
            }
        }
    }

    /// A thread is actionable when it is open and carries at least one comment.
    private static func isActionable(_ thread: ReviewThread) -> Bool {
        !thread.isResolved && !thread.isOutdated && !thread.comments.isEmpty
    }
}
