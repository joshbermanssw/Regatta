import Foundation
import Testing
import RegattaGitHub
import RegattaCore
@testable import RegattaFleet

/// **End-to-end pipeline integration test** for Regatta's PR-shepherd → worker →
/// fix → push loop.
///
/// Unlike the per-unit reactor tests (which stub the spawner, the gate, and the
/// diff probe), this suite wires the **real** production objects together and runs
/// the whole loop headlessly under `swift test` — no app, no UI, no network, no
/// real `claude`:
///
/// - real ``Fleet`` + ``ShepherdWatcher`` (driven by a scripted poller),
/// - the real ``CIFixReactor`` + ``FleetCIFixBridge``,
/// - the real ``RegattaOrchestrator`` + ``ProcessPaneBridge`` +
///   ``RegattaWorktreeManager`` + ``RegattaGitDiffProbe`` from `RegattaCore` — the
///   live spawn seams the app's `OrchestratorWorkerSpawner` wraps — reached through
///   ``LiveOrchestratorSpawner`` (a faithful in-test ``WorkerSpawning`` over those
///   exact seams, mirroring the app spawner's spawn → await-terminal → diff →
///   record-worktree logic),
/// - the real ``AutonomyGate`` + ``GitPushActionExecutor`` + a real `git push`
///   conformer + ``CIFixWorktreeStore`` (so the push is a genuine `git push` into a
///   real fixture remote),
/// - the real ``ShepherdWorkerRegistry`` and dismiss-cascade wiring.
///
/// Only **two** things are faked, and both are scripted processes / data — never
/// the real CLI and never the network:
/// 1. the **GitHub poller** (a scripted ``PullRequestPolling`` returning canned
///    check / comment / review snapshots), and
/// 2. the **agent process** — a fake-agent shell script the orchestrator launches
///    as a real subprocess, which makes a **real `git commit`** in the worktree
///    (the "fake-agent harness" the pipeline drives in place of `claude`).
///
/// Real fixture git repos under a temp dir back every scenario, so worktree
/// provisioning, commit-detection, and push are genuinely exercised.
@Suite("Regatta pipeline — end-to-end (real components, fake poller + fake agent)")
struct RegattaPipelineEndToEndTests {

    // MARK: - Scenario 1: CI-fix happy path (auto mode pushes; loop stops on green)

    /// A failing check → a ci-fix worker spawns in a real worktree → the fake agent
    /// **commits a fix** → the real diff probe detects it → the push is routed
    /// through the **real ``AutonomyGate`` in auto mode** → a **real `git push`**
    /// advances the fixture's branch → the next poll reports green → the loop
    /// **stops greenSuccess** (no further work).
    @Test("CI-fix happy path: auto push advances the branch, loop stops on green")
    func ciFixHappyPathAutoPushesAndStopsOnGreen() async throws {
        let env = try PipelineEnv(agentCommits: true, marker: "happy")
        defer { env.cleanup() }
        let pr = Self.ref(1)

        let originTipBefore = try env.fixture.tipSHA(env.fixture.origin)

        let worktreeStore = CIFixWorktreeStore()
        let gate = env.makeAutonomyGate(worktreeStore: worktreeStore)
        await gate.setMode(.auto, for: pr) // auto ⇒ push executes immediately

        let spawner = env.makeSpawner(worktreeStore: worktreeStore)

        // After the worker commits and the push lands, CI goes green: the loop
        // condition re-polls once and sees green, so the loop stops on the first
        // iteration (the realistic happy path — one fix, one push, then green).
        let poller = SequencedChecksPoller([.green(["build"])])
        let reactor = CIFixReactor(
            spawner: spawner,
            gate: gate,
            poller: poller,
            maxIterations: 5,
            // Resolve the real PR head branch (the fix for the wrong-branch bug the
            // integration test exposed). Without this the push targets a branch
            // named after the repo and the PR never gets the fix.
            headBranchResolver: { _ in env.fixture.branch }
        )

        let outcome = await reactor.runFixLoop(for: pr)

        #expect(outcome == .greenSuccess)

        // The real, gate-approved push advanced the fixture's branch on the remote.
        let originTipAfter = try env.fixture.tipSHA(env.fixture.origin)
        #expect(
            originTipAfter != originTipBefore,
            "the gate-approved push should advance origin/\(env.fixture.branch)"
        )
        // Exactly one fix attempt occurred (the agent committed once); greenSuccess
        // proves the loop terminated rather than respawning.
        #expect(spawner.spawnCount == 1)
    }

    // MARK: - Scenario 2: staged gate holds the push; approval executes it

    /// Same as the happy path, but autonomy = **staged**: the agent commits a fix
    /// and the loop authorizes the push, but the gate **holds it as a pending
    /// action** (not pushed). Approving the pending action executes the **real
    /// push**, advancing the branch.
    @Test("staged gate holds the push as a pending action; approval pushes for real")
    func stagedGateHoldsThenApproveExecutesPush() async throws {
        let env = try PipelineEnv(agentCommits: true, marker: "staged")
        defer { env.cleanup() }
        let pr = Self.ref(2)

        let originTipBefore = try env.fixture.tipSHA(env.fixture.origin)

        let worktreeStore = CIFixWorktreeStore()
        let gate = env.makeAutonomyGate(worktreeStore: worktreeStore)
        await gate.setMode(.staged, for: pr) // staged ⇒ push is held for approval

        let spawner = env.makeSpawner(worktreeStore: worktreeStore)
        // The condition never sees green on its own — only the approved push will.
        let poller = SequencedChecksPoller([.red(["build"])])
        let reactor = CIFixReactor(
            spawner: spawner, gate: gate, poller: poller, maxIterations: 1,
            headBranchResolver: { _ in env.fixture.branch }
        )

        let outcome = await reactor.runFixLoop(for: pr)

        // Staged ⇒ the loop is told the push was not performed ⇒ needsAttention
        // ("fix is staged but the push was blocked by the autonomy gate").
        guard case .needsAttention = outcome else {
            Issue.record("expected needsAttention while staged, got \(outcome)")
            return
        }

        // The push did NOT happen yet — origin is unchanged …
        #expect(try env.fixture.tipSHA(env.fixture.origin) == originTipBefore)

        // … but a pending push action is queued for this PR.
        let pending = await gate.currentPending(for: pr)
        #expect(pending.count == 1)
        let pushAction = try #require(pending.first)
        #expect(pushAction.kind == .push)
        #expect(pushAction.payload?["branch"] == env.fixture.branch)

        // Approving the pending action executes the real push → branch advances.
        let resolved = await gate.approve(pushAction.id)
        #expect(resolved?.status == .completed)
        #expect(
            try env.fixture.tipSHA(env.fixture.origin) != originTipBefore,
            "approving the staged push should advance origin/\(env.fixture.branch)"
        )
    }

    // MARK: - Scenario 3: no-progress stop → needsAttention, no respawn

    /// The fake agent makes **no commit** → the real diff probe reports "no fix" →
    /// the loop stops with **needsAttention** (the #92 behavior) and does **not**
    /// respawn another worker. The bridge then raises the Fleet's needs-attention
    /// banner with a reason.
    @Test("no-progress: agent makes no commit → loop stops needsAttention, no respawn")
    func noProgressStopsWithNeedsAttentionNoRespawn() async throws {
        let env = try PipelineEnv(agentCommits: false, marker: "noprogress")
        defer { env.cleanup() }
        let pr = Self.ref(3)

        let worktreeStore = CIFixWorktreeStore()
        let gate = env.makeAutonomyGate(worktreeStore: worktreeStore)
        await gate.setMode(.auto, for: pr)

        let spawner = env.makeSpawner(worktreeStore: worktreeStore)
        let poller = SequencedChecksPoller([.red(["build"]), .red(["build"])])
        let reactor = CIFixReactor(
            spawner: spawner, gate: gate, poller: poller, maxIterations: 5,
            headBranchResolver: { _ in env.fixture.branch }
        )

        // Drive via ingest() (the production entry point) on a failing snapshot so
        // the reactor runs the loop AND sets its needs-attention flag (#35/#92).
        let redState = ShepherdState(
            pullRequest: pr, phase: .watching,
            checks: PRCheckSummary(checks: SequencedChecksPoller.CheckStep.red(["build"]).checks)
        )
        let outcome = await reactor.ingest(redState)

        // The agent produced nothing fixable, so the loop gives up with a reason …
        guard case .needsAttention(let reason)? = outcome else {
            Issue.record("expected needsAttention, got \(String(describing: outcome))")
            return
        }
        #expect(reason.contains("build")) // names the still-failing check
        // … after exactly ONE spawn — no respawn on the same red snapshot.
        #expect(spawner.spawnCount == 1)
        // The reactor flagged the PR needs-attention so it stops auto-pushing (#35).
        #expect(await reactor.isNeedingAttention(pr))

        // The push never happened (nothing to push).
        #expect(await gate.currentPending(for: pr).isEmpty)

        // A repeat red snapshot must NOT respawn while flagged needs-attention.
        let again = await reactor.ingest(redState)
        #expect(again == nil)
        #expect(spawner.spawnCount == 1, "needs-attention suppresses respawn on a repeat red snapshot")
    }

    // MARK: - Scenario 4: skip rules (self / bot / answered) vs a real reviewer

    /// The conversation-comment reactor — wired to the **real** live spawner —
    /// spawns a worker for a genuine reviewer comment but skips the shepherd's own
    /// reply, a `[bot]` comment, and an already-answered comment.
    @Test("conversation skip rules: self / bot / answered are skipped; a reviewer spawns a worker")
    func conversationSkipRulesVsRealReviewer() async throws {
        let env = try PipelineEnv(agentCommits: true, marker: "skip")
        defer { env.cleanup() }
        let pr = Self.ref(4)

        let spawner = env.makeSpawner()
        let writer = RecordingPRWriter()
        // This scenario verifies the reactor's skip rules + that a real reviewer
        // comment drives the real live spawner; the autonomy gate is not under test
        // here (scenarios 1/2 + Scenario 6 cover it), so an allow-all gate keeps the
        // focus on skip logic. The reactor still resolves the PR head branch (the C1
        // fix: the addressing push carries the head branch, mirroring ci-fix), so the
        // worker pushes through the gate rather than declining.
        let gate = AllowAllOutwardActionGate()

        let reactor = ConversationCommentReactor(
            spawner: spawner,
            writer: writer,
            gate: gate,
            log: NoopConversationCommentLog(),
            selfLogin: { "shepherd-bot" },
            headBranchResolver: { _ in env.fixture.branch }
        )

        // A poll snapshot mixing skip-worthy comments with one genuine reviewer
        // comment. Self / bot / already-answered must be skipped; only the reviewer
        // comment spawns a worker.
        let comments: [PRConversationComment] = [
            comment(id: "self-1", author: "shepherd-bot", body: "my own reply"),
            comment(id: "bot-1", author: "vercel[bot]", body: "deploy preview"),
            comment(id: "rev-1", author: "alice", body: "Please rename this function."),
        ]
        let state = ShepherdState(
            pullRequest: pr, phase: .watching,
            conversationComments: comments
        )

        await reactor.react(to: state)

        // Exactly ONE worker spawned — for the genuine reviewer comment only.
        #expect(spawner.spawnCount == 0) // ci-fix spawn path untouched
        #expect(await reactor.handledCommentIDs == ["rev-1"])
        // The reviewer comment got a reply (the worker committed → reply posted).
        #expect(writer.conversationReplies.count == 1)

        // Already-answered guard: a comment BEFORE the shepherd's latest reply is
        // skipped. Build a timeline where the reviewer comment precedes a self reply.
        let answeredState = ShepherdState(
            pullRequest: pr, phase: .watching,
            conversationComments: [
                comment(id: "rev-old", author: "alice", body: "old point"),
                comment(id: "self-late", author: "shepherd-bot", body: "answered it"),
            ]
        )
        let reactor2 = ConversationCommentReactor(
            spawner: spawner, writer: writer, gate: gate,
            log: NoopConversationCommentLog(), selfLogin: { "shepherd-bot" },
            headBranchResolver: { _ in env.fixture.branch }
        )
        await reactor2.react(to: answeredState)
        // Nothing newly handled — the reviewer comment is already answered.
        #expect(await reactor2.handledCommentIDs.isEmpty)
    }

    // MARK: - Scenario 5: cancel/dismiss lifecycle stops the loop (no respawn)

    /// Cancelling the reactor's loop for a PR is a final stop: a subsequent red
    /// snapshot does **not** respawn a worker until a green snapshot re-arms it.
    @Test("cancel stops the loop: a later red snapshot does not respawn")
    func cancelStopsLoopNoRespawn() async throws {
        let env = try PipelineEnv(agentCommits: true, marker: "cancel")
        defer { env.cleanup() }
        let pr = Self.ref(5)

        let worktreeStore = CIFixWorktreeStore()
        let gate = env.makeAutonomyGate(worktreeStore: worktreeStore)
        await gate.setMode(.auto, for: pr)
        let registry = ShepherdWorkerRegistry()
        let spawner = env.makeSpawner(worktreeStore: worktreeStore, registry: registry)
        let poller = SequencedChecksPoller([.red(["build"])])
        let reactor = CIFixReactor(
            spawner: spawner, gate: gate, poller: poller, maxIterations: 5,
            headBranchResolver: { _ in env.fixture.branch }
        )

        let originTipBefore = try env.fixture.tipSHA(env.fixture.origin)

        // Cancel BEFORE any work: the loop must stop immediately as cancelled and
        // never run an agent fix attempt or push.
        await reactor.cancel(for: pr)
        let outcome = await reactor.runFixLoop(for: pr)
        #expect(outcome == .cancelled)
        // No agent fix ran ⇒ no push ⇒ the branch is untouched.
        #expect(try env.fixture.tipSHA(env.fixture.origin) == originTipBefore)
        #expect(await gate.currentPending(for: pr).isEmpty)
        // No worker was registered/run for this PR (the loop stopped before attempt).
        #expect(await registry.workerIDs(for: pr).isEmpty)

        // Feeding a red snapshot via ingest() after a cancel must NOT respawn (one
        // cancel = one stop) until a green snapshot re-arms it.
        let redState = ShepherdState(
            pullRequest: pr, phase: .watching,
            checks: PRCheckSummary(checks: SequencedChecksPoller.CheckStep.red(["build"]).checks)
        )
        let ingestOutcome = await reactor.ingest(redState)
        #expect(ingestOutcome == nil, "a cancelled PR must not respawn on a stale red snapshot")
        #expect(try env.fixture.tipSHA(env.fixture.origin) == originTipBefore)
    }

    /// Dismissing a shepherd cascades a cancel to its loop (and registered workers)
    /// via the Fleet's dismiss handler — the wiring that stops orphaned loops.
    @Test("dismiss cascades a cancel to the shepherd's loop")
    func dismissCascadesCancelToLoop() async throws {
        let env = try PipelineEnv(agentCommits: true, marker: "dismiss")
        defer { env.cleanup() }
        let pr = Self.ref(6)

        let worktreeStore = CIFixWorktreeStore()
        let gate = env.makeAutonomyGate(worktreeStore: worktreeStore)
        let registry = ShepherdWorkerRegistry()
        let spawner = env.makeSpawner(worktreeStore: worktreeStore, registry: registry)
        let poller = SequencedChecksPoller([.green(["build"])])
        let reactor = CIFixReactor(
            spawner: spawner, gate: gate, poller: poller, maxIterations: 5,
            headBranchResolver: { _ in env.fixture.branch }
        )

        // A real Fleet with the production dismiss-cascade wiring: dismissing the PR
        // must call reactor.cancel(for:) so the loop stops.
        let fleet = Fleet(autoStart: false, autonomyGate: gate) { ref in
            ShepherdWatcher(pullRequest: ref, poller: poller)
        }
        await fleet.setDismissHandler { dismissed in
            await reactor.cancel(for: dismissed)
        }
        await fleet.handoff(pr, repositoryDirectory: env.fixture.checkout, headBranch: env.fixture.branch)
        #expect(await fleet.contains(pr))

        await fleet.dismiss(pr)

        // The dismiss cascade flagged the loop cancelled: a fresh red snapshot does
        // not respawn (until a green re-arm), proving the loop was stopped.
        #expect(!(await fleet.contains(pr)))
        let redState = ShepherdState(
            pullRequest: pr, phase: .watching,
            checks: PRCheckSummary(checks: SequencedChecksPoller.CheckStep.red(["build"]).checks)
        )
        let ingestAfterDismiss = await reactor.ingest(redState)
        #expect(ingestAfterDismiss == nil, "a dismissed shepherd's loop must not respawn")
        #expect(spawner.spawnCount == 0)
    }

    // MARK: - Scenario 6: review-thread addressing push lands on the PR branch (C1)

    /// A reviewer comment on a thread → the real live spawner runs the fake agent
    /// which **commits a fix** → the real diff probe detects it → the push is routed
    /// through the **real ``AutonomyGate`` in auto mode** carrying the PR head branch
    /// → a **real `git push`** advances the fixture branch → the thread is replied to,
    /// resolved, and marked **handled** (no respawn on the next poll).
    ///
    /// This is the regression guard for C1 on the review-thread path: before the fix
    /// the push carried no branch and the production executor threw `missingBranch`,
    /// so the thread was never handled and re-spawned forever.
    @Test("review-thread addressing: auto push advances the branch, thread handled (C1)")
    func reviewThreadAddressingAutoPushLandsOnBranch() async throws {
        let env = try PipelineEnv(agentCommits: true, marker: "thread-auto")
        defer { env.cleanup() }
        let pr = Self.ref(7)

        let originTipBefore = try env.fixture.tipSHA(env.fixture.origin)

        let worktreeStore = CIFixWorktreeStore()
        let gate = env.makeAutonomyGate(worktreeStore: worktreeStore)
        await gate.setMode(.auto, for: pr) // auto ⇒ push executes immediately

        let spawner = env.makeSpawner(worktreeStore: worktreeStore)
        let writer = RecordingPRWriter()
        let reactor = ReviewThreadReactor(
            spawner: spawner,
            writer: writer,
            gate: gate,
            log: NoopReviewThreadLog(),
            selfLogin: { "shepherd-bot" },
            headBranchResolver: { _ in env.fixture.branch }
        )

        let state = ShepherdState(
            pullRequest: pr, phase: .watching,
            reviewThreads: [Self.thread("T1", author: "alice")]
        )
        await reactor.react(to: state)

        // The real, gate-approved push advanced the fixture branch on the remote.
        #expect(
            try env.fixture.tipSHA(env.fixture.origin) != originTipBefore,
            "the gate-approved addressing push should advance origin/\(env.fixture.branch)"
        )
        // The thread was fully handled (replied + resolved) → recorded so it never
        // re-spawns on the next identical poll.
        #expect(await reactor.handledThreadIDs == ["T1"])
        #expect(writer.threadReplies.map(\.threadID) == ["T1"])
        #expect(writer.resolvedThreads == ["T1"])

        // Next poll with the same thread spawns nothing (handled = no respawn).
        await reactor.react(to: state)
        #expect(await reactor.handledThreadIDs == ["T1"])
        #expect(writer.threadReplies.count == 1, "a handled thread is not re-addressed")
    }

    // MARK: - Scenario 7: conversation-comment addressing — staged holds the push (C1)

    /// A reviewer conversation comment → the agent commits a fix → the loop routes
    /// the push through the **staged** gate, which **holds it as a pending action**
    /// carrying the PR head branch (not pushed). The comment is therefore **not**
    /// marked handled (it retries once approved), and approving the pending action
    /// runs the **real push**.
    @Test("conversation addressing: staged gate holds a branch-carrying pending push (C1)")
    func conversationAddressingStagedHoldsPendingPush() async throws {
        let env = try PipelineEnv(agentCommits: true, marker: "conv-staged")
        defer { env.cleanup() }
        let pr = Self.ref(8)

        let originTipBefore = try env.fixture.tipSHA(env.fixture.origin)

        let worktreeStore = CIFixWorktreeStore()
        let gate = env.makeAutonomyGate(worktreeStore: worktreeStore)
        await gate.setMode(.staged, for: pr) // staged ⇒ push held for approval

        let spawner = env.makeSpawner(worktreeStore: worktreeStore)
        let writer = RecordingPRWriter()
        let reactor = ConversationCommentReactor(
            spawner: spawner,
            writer: writer,
            gate: gate,
            log: NoopConversationCommentLog(),
            selfLogin: { "shepherd-bot" },
            headBranchResolver: { _ in env.fixture.branch }
        )

        let state = ShepherdState(
            pullRequest: pr, phase: .watching,
            conversationComments: [comment(id: "C1", author: "alice", body: "Please rename foo().")]
        )
        await reactor.react(to: state)

        // Staged ⇒ the push is held, origin unchanged, and the comment is NOT handled.
        #expect(try env.fixture.tipSHA(env.fixture.origin) == originTipBefore)
        #expect(await reactor.handledCommentIDs.isEmpty, "a held push leaves the comment for retry")

        // A pending push action is queued for this PR, carrying the head branch.
        let pending = await gate.currentPending(for: pr)
        let pushAction = try #require(pending.first { $0.kind == .push })
        #expect(pushAction.payload?["branch"] == env.fixture.branch)
        #expect(pushAction.payload?["commentID"] == "C1")

        // Approving the pending action runs the real push → branch advances.
        let resolved = await gate.approve(pushAction.id)
        #expect(resolved?.status == .completed)
        #expect(
            try env.fixture.tipSHA(env.fixture.origin) != originTipBefore,
            "approving the staged addressing push should advance origin/\(env.fixture.branch)"
        )
    }

    // MARK: - Scenario 8: review-summary addressing push lands on the PR branch (C1)

    /// A submitted CHANGES_REQUESTED review → the agent commits a fix → the auto gate
    /// routes the branch-carrying push → a real `git push` advances the branch → the
    /// review is marked handled (no respawn).
    @Test("review-summary addressing: auto push advances the branch, review handled (C1)")
    func reviewSummaryAddressingAutoPushLandsOnBranch() async throws {
        let env = try PipelineEnv(agentCommits: true, marker: "review-auto")
        defer { env.cleanup() }
        let pr = Self.ref(9)

        let originTipBefore = try env.fixture.tipSHA(env.fixture.origin)

        let worktreeStore = CIFixWorktreeStore()
        let gate = env.makeAutonomyGate(worktreeStore: worktreeStore)
        await gate.setMode(.auto, for: pr)

        let spawner = env.makeSpawner(worktreeStore: worktreeStore)
        let writer = RecordingPRWriter()
        let reactor = ReviewSummaryReactor(
            spawner: spawner,
            writer: writer,
            gate: gate,
            log: NoopReviewSummaryLog(),
            selfLogin: { "shepherd-bot" },
            headBranchResolver: { _ in env.fixture.branch }
        )

        let state = ShepherdState(
            pullRequest: pr, phase: .watching,
            reviews: [makeReview("R1", author: "alice", state: .changesRequested, body: "fix the empty case")]
        )
        await reactor.react(to: state)

        #expect(
            try env.fixture.tipSHA(env.fixture.origin) != originTipBefore,
            "the gate-approved review push should advance origin/\(env.fixture.branch)"
        )
        #expect(await reactor.handledReviewIDs == ["R1"])

        // No respawn on the next identical poll.
        await reactor.react(to: state)
        #expect(await reactor.handledReviewIDs == ["R1"])
    }

    // MARK: - Scenario 9: unresolved head branch → decline, no push, retry (C1 guard)

    /// When the PR head branch cannot be resolved, the addressing worker must
    /// **decline** the push (never push to a junk branch) and leave the thread
    /// unhandled for a later retry — the C1 decline guard mirroring ci-fix.
    @Test("addressing decline guard: unresolved branch never pushes, leaves work for retry (C1)")
    func addressingDeclinesWhenBranchUnresolved() async throws {
        let env = try PipelineEnv(agentCommits: true, marker: "no-branch")
        defer { env.cleanup() }
        let pr = Self.ref(10)

        let originTipBefore = try env.fixture.tipSHA(env.fixture.origin)

        let worktreeStore = CIFixWorktreeStore()
        let gate = env.makeAutonomyGate(worktreeStore: worktreeStore)
        await gate.setMode(.auto, for: pr)

        let spawner = env.makeSpawner(worktreeStore: worktreeStore)
        let writer = RecordingPRWriter()
        let reactor = ReviewThreadReactor(
            spawner: spawner,
            writer: writer,
            gate: gate,
            log: NoopReviewThreadLog(),
            selfLogin: { "shepherd-bot" },
            headBranchResolver: { _ in nil } // unresolved
        )

        await reactor.react(to: ShepherdState(
            pullRequest: pr, phase: .watching,
            reviewThreads: [Self.thread("T1", author: "alice")]
        ))

        // No push happened (origin unchanged) and the thread is NOT handled.
        #expect(try env.fixture.tipSHA(env.fixture.origin) == originTipBefore)
        #expect(await reactor.handledThreadIDs.isEmpty)
        #expect(writer.threadReplies.isEmpty, "a declined push must not reply/resolve")
        #expect(await gate.currentPending(for: pr).isEmpty)
    }

    // MARK: - Scenario 10: cancel/dismiss stops the addressing reactors (I1/I2)

    /// `forget(for:)` (the dismiss/worker-✕ shared stop) clears an addressing
    /// reactor's handled state **and** guards a late snapshot so it does not
    /// re-trigger — and a fresh `rearm(for:)` (re-handoff) resumes it. This is the
    /// I1/I2 lifecycle guard against the respawn-after-cancel hole.
    @Test("cancel/dismiss stops the addressing reactor; re-handoff resumes it (I1/I2)")
    func dismissStopsAddressingReactorAndReHandoffResumes() async throws {
        let env = try PipelineEnv(agentCommits: true, marker: "addr-dismiss")
        defer { env.cleanup() }
        let pr = Self.ref(11)

        let gate = AllowAllOutwardActionGate()
        let registry = ShepherdWorkerRegistry()
        let spawner = env.makeSpawner(registry: registry)
        let reactor = ConversationCommentReactor(
            spawner: spawner,
            writer: RecordingPRWriter(),
            gate: gate,
            log: NoopConversationCommentLog(),
            selfLogin: { "shepherd-bot" },
            headBranchResolver: { _ in env.fixture.branch }
        )

        // Handle one comment, then dismiss (forget) the shepherd.
        await reactor.react(to: ShepherdState(
            pullRequest: pr, phase: .watching,
            conversationComments: [comment(id: "C1", author: "alice", body: "rename foo()")]
        ))
        #expect(await reactor.handledCommentIDs == ["C1"])
        let spawnsBeforeDismiss = spawner.conversationSpawnCount

        await reactor.forget(for: pr) // dismiss / worker-✕ shared stop

        // A late snapshot (new comment) for the dismissed PR must NOT spawn.
        await reactor.react(to: ShepherdState(
            pullRequest: pr, phase: .watching,
            conversationComments: [comment(id: "C2", author: "alice", body: "another note")]
        ))
        #expect(
            spawner.conversationSpawnCount == spawnsBeforeDismiss,
            "a dismissed PR's reactor must not spawn on a late snapshot"
        )
        #expect(await reactor.handledCommentIDs.isEmpty, "forget cleared the PR's handled state")

        // A fresh handoff re-arms it: a new comment is addressed again.
        await reactor.rearm(for: pr)
        await reactor.react(to: ShepherdState(
            pullRequest: pr, phase: .watching,
            conversationComments: [comment(id: "C3", author: "alice", body: "addressed?")]
        ))
        #expect(await reactor.handledCommentIDs == ["C3"], "a re-handed-off PR resumes addressing")
    }

    // MARK: - Scenario 11: worker-row ✕ shared cancel stops the ci-fix loop (I1)

    /// The Fleet ✕ on a single worker row must route through the same per-PR stop
    /// the dismiss cascade uses: resolve the worker → PR via the registry, then
    /// cancel the ci-fix reactor for that PR so its "until green" loop does NOT
    /// respawn a replacement. This drives the exact shared-path pieces the app's
    /// `RegattaFleetManager.cancelWorker(_:)` composes, end-to-end.
    @Test("worker-row ✕: registry reverse-lookup + reactor cancel stops the loop (I1)")
    func workerRowCancelStopsCIFixLoopNoRespawn() async throws {
        let env = try PipelineEnv(agentCommits: true, marker: "row-cancel")
        defer { env.cleanup() }
        let pr = Self.ref(12)

        let worktreeStore = CIFixWorktreeStore()
        let gate = env.makeAutonomyGate(worktreeStore: worktreeStore)
        await gate.setMode(.auto, for: pr)
        let registry = ShepherdWorkerRegistry()
        let spawner = env.makeSpawner(worktreeStore: worktreeStore, registry: registry)
        let poller = SequencedChecksPoller([.red(["build"])])
        let reactor = CIFixReactor(
            spawner: spawner, gate: gate, poller: poller, maxIterations: 5,
            headBranchResolver: { _ in env.fixture.branch }
        )

        // Simulate the worker-row ✕ shared path BEFORE the loop runs: a worker is
        // registered for the PR, the user clicks ✕ on that row → resolve PR via the
        // registry reverse-lookup, then cancel the reactor for that PR.
        let workerID = UUID()
        await registry.record(workerID, for: pr)
        let resolvedPR = try #require(await registry.pullRequest(for: workerID))
        #expect(resolvedPR == pr)
        await reactor.cancel(for: resolvedPR) // the I1 wiring the row ✕ must do

        let originTipBefore = try env.fixture.tipSHA(env.fixture.origin)

        // The loop now stops immediately as cancelled — no agent fix attempt runs,
        // so no NEW worker is registered for the PR beyond the one we recorded above,
        // and nothing is pushed.
        let outcome = await reactor.runFixLoop(for: pr)
        #expect(outcome == .cancelled)
        #expect(
            await registry.workerIDs(for: pr) == [workerID],
            "the cancelled loop must not run (register) a replacement worker"
        )
        #expect(try env.fixture.tipSHA(env.fixture.origin) == originTipBefore, "no push on a cancelled loop")

        // And a later red snapshot does not respawn (one cancel = one stop).
        let redState = ShepherdState(
            pullRequest: pr, phase: .watching,
            checks: PRCheckSummary(checks: SequencedChecksPoller.CheckStep.red(["build"]).checks)
        )
        #expect(await reactor.ingest(redState) == nil, "a row-cancelled loop must not respawn")
        #expect(try env.fixture.tipSHA(env.fixture.origin) == originTipBefore)
    }

    // MARK: - Helpers

    static func ref(_ number: Int = 1) -> PullRequestRef {
        PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: number)
    }

    /// Builds an open, commented review thread authored by `author`.
    static func thread(_ id: String, author: String) -> ReviewThread {
        ReviewThread(
            id: id,
            isResolved: false,
            isOutdated: false,
            path: "Sources/\(id).swift",
            comments: [
                ReviewComment(
                    id: "\(id)-c0", body: "please fix", author: author,
                    url: "https://github.com/joshbermanssw/regatta/pull/4/\(id)"
                ),
            ]
        )
    }

    private func comment(id: String, author: String, body: String) -> PRConversationComment {
        PRConversationComment(
            id: id, body: body, author: author,
            url: "https://github.com/joshbermanssw/regatta/pull/4#\(id)",
            createdAt: "2026-06-25T12:00:00Z"
        )
    }
}
