# RegattaFleet

The Regatta Fleet domain: long-lived **PR shepherd watchers**.

A shepherd is a persistent Fleet entity (distinct from an ephemeral worker) that
polls one pull request's CI checks and review threads and reacts to changes.
Issue #29 builds the handoff + watcher + initial polling; the CI watch loop
(fix-until-green, #30) reacts to failing checks; review-thread handling (#31) is
a later issue.

## Types

- `PullRequestRef` — stable, case-insensitive PR identity (`owner/repo#number`).
  The Fleet keys shepherds on this, which is what makes handoff idempotent.
- `FleetEntry` / `FleetEntryKind` — the minimal seam for a Fleet member. Defined
  here so the shepherd ships before the orchestrator entity model (#16) lands.
  `kind` distinguishes a persistent `.shepherd` from an ephemeral `.worker`.
- `ShepherdState` — an immutable, `Sendable` snapshot (PR ref, poll phase,
  `PRCheckSummary`, review threads). Conforms to `FleetEntry`.
- `ShepherdWatcher` (actor) — polls one PR via `PullRequestPolling` and publishes
  `ShepherdState` over an `AsyncStream`.
- `Fleet` (actor) — owns one watcher per PR; `handoff(_:)` is idempotent on PR
  identity; `snapshots()` streams the full shepherd list.

### CI watch loop (#30)

When a shepherd's checks transition to failing, the CI watch loop spawns a
`ci-fix` worker scoped to the PR branch and loops "until checks green", pushing
fixes and re-polling until green or a cap is hit.

- `CIFixReactor` (actor) — observes `ShepherdState` failure transitions, spawns a
  worker via `WorkerSpawning`, drives the fix loop, routes pushes through
  `OutwardActionGate`, and publishes a `CIFixOutcome`.
- `CIFixLoopCondition` (actor) — the "until checks green" exit condition; re-polls
  via `PullRequestPolling`, stops on green or at the cap, continues on red.
- `CIFixOutcome` — `.greenSuccess` or `.needsAttention(reason:)` (cap reached or
  push denied).
- `FleetCIFixBridge` (actor) — the wiring hook; forwards `Fleet.snapshots()` into
  a `CIFixReactor` without touching the Fleet's internals.

### Cross-branch seams (defined locally, replaced when those issues merge)

- `LoopConditionEvaluating` / `LoopDecision` mirror the loop engine's pluggable
  condition (#19). `CIFixLoopCondition` conforms; when #19 lands it becomes a
  `RegattaLoopCondition` and the engine drives it.
- `WorkerSpawning` / `CIFixWorkerHandle` / `CIFixWorkerSpec` mirror the pane
  bridge / orchestrator (#14/#16). The composition root injects the real spawner.
- `OutwardActionGate` / `OutwardAction` mirror the autonomy gate (#32). Every push
  is routed through it; #32 supplies the real gate.

## Dependency seam

`Fleet` and `ShepherdWatcher` depend on `RegattaGitHub.PullRequestPolling`, the
protocol that `GitHubPoller` (the #28 `gh` polling layer) conforms to. The Fleet
**reuses** that layer; it does not reimplement `gh` polling.

## Testing

Inject a fake `PullRequestPolling` and build the Fleet with `autoStart: false` so
tests drive polls deterministically via `ShepherdWatcher.pollOnce()` — no real
process, network, or wall-clock waiting:

```swift
let poller = FakePullRequestPoller(checks: [...], threads: [...])
let fleet = Fleet(autoStart: false) { ref in
    ShepherdWatcher(pullRequest: ref, poller: poller)
}
let watcher = await fleet.handoff(.init(owner: "o", repo: "r", number: 1))
await watcher.pollOnce()
```

## Wiring (#16)

When the orchestrator's richer Fleet entity arrives, ephemeral workers join the
same Fleet; the `FleetEntry` seam already distinguishes the two kinds.
