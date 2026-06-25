import Foundation
import RegattaCore
import RegattaFleet
import RegattaGitHub
import RegattaPersistence

/// A thin `@MainActor` seam holding the app-lifetime Fleet object graph so that
/// the brain, the Fleet rail, the handoff action, and `AppDelegate` teardown all
/// share a single ``RegattaOrchestrator`` and a single ``Fleet``.
///
/// The orchestrator owns ephemeral brain-spawned worker lifecycle; the Fleet owns
/// every long-lived PR shepherd watcher. Both need to be shared app-wide and
/// there is no other injection path between the composition root and the SwiftUI
/// view tree, so — like ``RegattaMemoryManager`` / ``RegattaBrainManager`` — a
/// singleton is warranted. The seam holds no domain logic beyond constructing the
/// object graph once and mirroring the concurrency cap into the orchestrator.
///
/// ## Pane Bridge dependency (#14)
/// The orchestrator is constructed with the real ``ProcessPaneBridge``: it spawns
/// each worker's agent as a subprocess in its provisioned worktree and streams
/// stdout/stderr/termination back through the ``PaneBridge`` seam.
@MainActor
final class RegattaFleetManager {

    /// Shared instance accessed by the rail view, the brain spawn path, and the
    /// handoff action.
    static let shared = RegattaFleetManager()

    /// The app-lifetime orchestrator that provisions worktrees and launches
    /// ephemeral workers.
    let orchestrator: RegattaOrchestrator

    /// The shared production ``Fleet`` (real `gh`-backed poller) that owns
    /// persistent PR shepherds.
    let fleet: Fleet

    /// The production ``WorkerSpawning`` conformer the reactive layers spawn real
    /// agent workers through (Seam A). Exposed so other composition sites (e.g. a
    /// loop view bound to a live worker) reuse the same live spawn path.
    let workerSpawner: OrchestratorWorkerSpawner

    /// Maps each PR to the worktree its most recent ci-fix worker committed into,
    /// so the gate-routed ``GitPushActionExecutor`` pushes exactly those commits.
    private let ciFixWorktreeStore: CIFixWorktreeStore

    /// Tracks which workers each shepherd (PR) currently owns, so dismissing a
    /// shepherd cascades a cancel to its in-flight workers (and the ci-fix loop).
    private let workerRegistry: ShepherdWorkerRegistry

    /// The CI-fix reactor that spawns a real `ci-fix` worker when a shepherd's
    /// checks turn red (#30), retained for the app's lifetime.
    private let ciFixReactor: CIFixReactor

    /// The review-thread reactor that spawns a real addressing worker for each new
    /// reviewer comment (#31), retained for the app's lifetime.
    private let reviewThreadReactor: ReviewThreadReactor

    /// The bridge forwarding Fleet snapshots to the CI-fix reactor.
    private let ciFixBridge: FleetCIFixBridge

    /// The bridge forwarding Fleet snapshots to the review-thread reactor.
    private let reviewThreadBridge: FleetReviewThreadBridge

    /// The conversation-comment reactor that spawns a real addressing worker for
    /// each new top-level PR comment (skipping the shepherd's own replies),
    /// retained for the app's lifetime.
    private let conversationCommentReactor: ConversationCommentReactor

    /// The bridge forwarding Fleet snapshots to the conversation-comment reactor.
    private let conversationCommentBridge: FleetConversationCommentBridge

    /// The review-summary reactor that spawns a real addressing worker for each
    /// new actionable submitted review (Approve / Request changes / Comment
    /// summary), skipping the shepherd's own reviews, retained for the app's
    /// lifetime.
    private let reviewSummaryReactor: ReviewSummaryReactor

    /// The bridge forwarding Fleet snapshots to the review-summary reactor.
    private let reviewSummaryBridge: FleetReviewSummaryBridge

    private let defaults: UserDefaults
    private var defaultsObserver: NSObjectProtocol?

    private init() {
        self.defaults = .standard
        let cap = RegattaConcurrencySettings(defaults: defaults).maxConcurrentWorkers
        let orchestrator = RegattaOrchestrator(
            worktreeManager: RegattaWorktreeManager(
                baseDirectory: RegattaWorktreeManager.defaultBaseDirectory()
            ),
            paneBridge: ProcessPaneBridge(),
            maxConcurrentWorkers: cap
        )
        self.orchestrator = orchestrator

        // One shared `gh`-backed poller drives both the Fleet's shepherd watchers
        // and the CI-fix reactor's "until green" loop condition.
        let poller = GitHubPoller()

        // Workers are prompted to commit locally, not push; the push is routed
        // through the autonomy gate and performed here by a real `git push`. The
        // ci-fix worker records the worktree it committed into; this resolver reads
        // it back so the gate-approved push targets exactly those commits and is
        // run by Regatta (never the agent), keeping the staged-approval gate
        // meaningful (Parts B + C of the worker-can-act fix).
        let ciFixWorktreeStore = CIFixWorktreeStore()
        self.ciFixWorktreeStore = ciFixWorktreeStore
        let workerRegistry = ShepherdWorkerRegistry()
        self.workerRegistry = workerRegistry
        let pushExecutor = GitPushActionExecutor(
            resolveWorktree: { action in await ciFixWorktreeStore.worktree(for: action.pullRequest) },
            pusher: RegattaGitWorktreePusher()
        )
        let autonomyGate = AutonomyGate(executor: pushExecutor)
        let fleet = Fleet(poller: poller, autonomyGate: autonomyGate)
        self.fleet = fleet

        // Seam A: the live spawner backs both reactors with real agent workers.
        // Bug 1: resolve each PR's real on-disk checkout from the Fleet's handoff
        // map instead of defaulting to the launched app's `/` working directory.
        // A PR with no recorded checkout resolves to `nil`, and the spawner then
        // declines to run (surfaced cleanly) rather than failing inside `/`.
        let directories = fleet.repositoryDirectories
        let spawner = OrchestratorWorkerSpawner(
            orchestrator: orchestrator,
            repoURLResolver: { ref in await directories.directory(for: ref) },
            onMissingRepository: { ref in
                await RegattaToastCenter.shared.error(
                    String(
                        localized: "regatta.spawn.noCheckout.title",
                        defaultValue: "No local checkout for this PR"
                    ),
                    String.localizedStringWithFormat(
                        String(
                            localized: "regatta.spawn.noCheckout.message",
                            defaultValue: "Re-hand PR #%lld off from its workspace so Regatta knows where to run."
                        ),
                        ref.number
                    )
                )
            },
            onUnresolvableAgent: { error in
                await RegattaToastCenter.shared.error(
                    String(
                        localized: "regatta.spawn.unresolvableAgent.title",
                        defaultValue: "Agent CLI not found"
                    ),
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            },
            ciFixWorktreeStore: ciFixWorktreeStore,
            workerRegistry: workerRegistry
        )
        self.workerSpawner = spawner

        // CI-fix loop (#30): spawn a real worker on red checks, push through the
        // Fleet's real autonomy gate, and re-poll checks until green or capped.
        // Resolve each PR's real head branch (captured at handoff) so the
        // gate-routed ci-fix push targets the PR's branch — not a junk branch named
        // after the repo (the wrong-push-branch bug the e2e integration test
        // exposed). A PR with no recorded branch resolves to `nil` and the reactor
        // declines to push to a wrong branch.
        let headBranches = fleet.headBranches
        let ciFixReactor = CIFixReactor(
            spawner: spawner,
            gate: fleet.autonomyGate,
            poller: poller,
            headBranchResolver: { ref in await headBranches.branch(for: ref) }
        )
        self.ciFixReactor = ciFixReactor
        self.ciFixBridge = FleetCIFixBridge(fleet: fleet, reactor: ciFixReactor)

        // Review-thread handler (#31): spawn a real addressing worker per new
        // reviewer comment, gated and writing back through the real `gh` writer.
        // The self-login provider resolves the authenticated `gh` user so the
        // reactor skips the user's own / already-answered threads (and all bots).
        let reviewThreadReactor = ReviewThreadReactor(
            spawner: spawner,
            writer: poller,
            gate: fleet.autonomyGate,
            log: RegattaReviewThreadActivityLogger(),
            selfLogin: { try? await poller.currentUserLogin() }
        )
        self.reviewThreadReactor = reviewThreadReactor
        self.reviewThreadBridge = FleetReviewThreadBridge(fleet: fleet, reactor: reviewThreadReactor)

        // Conversation-comment handler: spawn a real addressing worker per new
        // top-level PR comment, gated and writing back through the real `gh`
        // writer. The self-login provider resolves the authenticated `gh` user so
        // the reactor skips the shepherd's own replies (loop prevention).
        let conversationCommentReactor = ConversationCommentReactor(
            spawner: spawner,
            writer: poller,
            gate: fleet.autonomyGate,
            log: RegattaConversationCommentActivityLogger(),
            selfLogin: { try? await poller.currentUserLogin() }
        )
        self.conversationCommentReactor = conversationCommentReactor
        self.conversationCommentBridge = FleetConversationCommentBridge(
            fleet: fleet, reactor: conversationCommentReactor
        )

        // Review-summary handler: spawn a real addressing worker per new
        // actionable submitted review (e.g. a PR approved with a summary note, or
        // a changes-requested review), gated and writing back through the real
        // `gh` writer. The self-login provider resolves the authenticated `gh`
        // user so the reactor skips the shepherd's own reviews (loop prevention).
        let reviewSummaryReactor = ReviewSummaryReactor(
            spawner: spawner,
            writer: poller,
            gate: fleet.autonomyGate,
            log: RegattaReviewSummaryActivityLogger(),
            selfLogin: { try? await poller.currentUserLogin() }
        )
        self.reviewSummaryReactor = reviewSummaryReactor
        self.reviewSummaryBridge = FleetReviewSummaryBridge(
            fleet: fleet, reactor: reviewSummaryReactor
        )

        // Dismiss cascade: when a shepherd card's ✕ dismisses a PR, cancel
        // everything that shepherd spawned so nothing keeps polling/spawning
        // orphaned (the dogfooded runaway). This cancels the ci-fix "until green"
        // loop and every in-flight worker the PR owns (ci-fix iteration worker +
        // review/conversation/review-summary addressing workers).
        Task { [fleet, ciFixReactor, orchestrator, workerRegistry] in
            await fleet.setDismissHandler { pr in
                await ciFixReactor.cancel(for: pr)
                for workerID in await workerRegistry.workerIDs(for: pr) {
                    try? await orchestrator.cancelWorker(workerID)
                }
                await workerRegistry.removeAll(for: pr)
            }
        }

        observeConcurrencyCap()
        startReactors()
    }

    /// Starts all Fleet→reactor bridges so handing a PR off actually reacts to CI
    /// failures, new review threads, new conversation comments, and new review
    /// summaries end-to-end. Idempotent (each bridge's `start()` is a no-op once
    /// running).
    private func startReactors() {
        Task { [ciFixBridge, reviewThreadBridge, conversationCommentBridge, reviewSummaryBridge] in
            await ciFixBridge.start()
            await reviewThreadBridge.start()
            await conversationCommentBridge.start()
            await reviewSummaryBridge.start()
        }
    }

    /// Resumes persisted PR shepherds into the live Fleet on launch (issue #34).
    ///
    /// For each persisted shepherd snapshot, this re-hands-off the PR to the
    /// shared ``Fleet`` — which is idempotent on PR identity and auto-starts the
    /// watcher, so polling resumes automatically — and restores the PR's saved
    /// ``AutonomyMode``. PR shepherds are event-driven, so this fully restores
    /// them without resuming any process.
    ///
    /// - Parameter snapshot: The restored state snapshot from
    ///   ``RegattaPersistenceManager/loadRestoredSnapshot()``.
    func resumeShepherds(from snapshot: RegattaStateSnapshot) async {
        for shepherd in snapshot.shepherds {
            let pr = shepherd.pullRequest
            await fleet.handoff(pr)
            let mode = snapshot.autonomyModes[pr.id] ?? shepherd.autonomyMode
            await fleet.setAutonomyMode(mode, for: pr)
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    /// Mirrors live `regatta.maxConcurrentWorkers` config changes into the
    /// orchestrator so editing the cap in Settings (or `cmux.json`) takes effect
    /// without restarting — promoting queued workers when raised, holding new
    /// spawns when lowered. The settings file store applies the JSON value into
    /// `UserDefaults.standard`, which posts `didChangeNotification`.
    private func observeConcurrencyCap() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let cap = RegattaConcurrencySettings(defaults: self.defaults).maxConcurrentWorkers
            Task { [orchestrator] in
                await orchestrator.setMaxConcurrentWorkers(cap)
            }
        }
    }
}
