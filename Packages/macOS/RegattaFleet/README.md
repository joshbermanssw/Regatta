# RegattaFleet

The Regatta Fleet domain: long-lived **PR shepherd watchers**.

A shepherd is a persistent Fleet entity (distinct from an ephemeral worker) that
polls one pull request's CI checks and review threads and reacts to changes.
Issue #29 builds the handoff + watcher + initial polling; reacting to CI
(fix-until-green, #30) and review-thread handling (#31) are later issues.

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
