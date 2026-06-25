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
        // here (scenarios 1/2 cover it), so an allow-all gate keeps the focus on
        // skip logic. (Conversation/review code-change pushes carry no branch, so
        // they are not routed through the branch-requiring GitPushActionExecutor.)
        let gate = AllowAllOutwardActionGate()

        let reactor = ConversationCommentReactor(
            spawner: spawner,
            writer: writer,
            gate: gate,
            log: NoopConversationCommentLog(),
            selfLogin: { "shepherd-bot" }
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
            log: NoopConversationCommentLog(), selfLogin: { "shepherd-bot" }
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

    // MARK: - Helpers

    static func ref(_ number: Int = 1) -> PullRequestRef {
        PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: number)
    }

    private func comment(id: String, author: String, body: String) -> PRConversationComment {
        PRConversationComment(
            id: id, body: body, author: author,
            url: "https://github.com/joshbermanssw/regatta/pull/4#\(id)",
            createdAt: "2026-06-25T12:00:00Z"
        )
    }
}
