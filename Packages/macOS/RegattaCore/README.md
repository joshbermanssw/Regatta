# RegattaCore

RegattaCore is the foundational backend package for the Regatta feature (parallel AI-agent orchestration inside cmux). It provides `RegattaWorktreeManager` — an actor that provisions and cleans up isolated git worktrees for parallel workers — along with `RegattaWorktree` (the value record a worktree returns) and `WorktreeError` (the error enum). The package's tests include the `FakeAgent` harness that drives `fake-agent.sh` via `Process`, exercising the same subprocess spawn path used by the real orchestrator. Tests run headlessly via `swift test` (no app host required), which is the whole point: subprocess-spawning tests that previously hung inside the cmux app-host test runner now execute reliably in SwiftPM's own runner.

## Orchestrator (issue #16)

`RegattaOrchestrator` is the actor that turns a brain request into a Fleet worker. Given a `WorkerSpec` (a goal/prompt, a target repo, and a `WorkerAgentLaunch`) it:

1. registers the worker as `.queued` and returns its `UUID` immediately,
2. provisions an isolated worktree via `RegattaWorktreeManager`,
3. launches the agent in that worktree via a `PaneBridge`,
4. drives the worker's `WorkerStatus` from the real process lifecycle (`.running` → `.done`/`.failed`), and
5. cancels a worker on request (terminating the process and cleaning up).

Status changes are broadcast as `[Worker]` snapshots on the `AsyncStream` returned by `updates()`. `Worker` is a `Sendable` value type, so the Fleet UI feeds these snapshots straight into `ForEach` rows without ever crossing the SwiftUI list snapshot boundary with an actor reference.

### PaneBridge seam (issue #14)

`PaneBridge` is the protocol seam between the orchestrator and an agent's live process surface: `spawn(PaneSpec) -> PaneHandle`, `terminate(PaneHandle.ID)`, and `isRunning(PaneHandle.ID)`. The handle exposes the process output as `AsyncStream<PaneOutputEvent>` (`.stdout` / `.stderr` / `.terminated(code)`). The orchestrator depends only on this protocol — the production `ProcessPaneBridge` (issue #14) and the headless test fake both conform. Until #14 lands, `UnavailablePaneBridge` is the production placeholder: every `spawn` fails with a clear "depends on #14" message so a requested worker surfaces as `.failed` rather than silently doing nothing.

### Testing the orchestrator

`RegattaOrchestratorTests` drives the full spawn lifecycle headlessly: a real `RegattaWorktreeManager` over a temp-dir fixture git repo (so worktree provisioning is exercised end-to-end) plus a `FakePaneBridge` standing in for the Pane Bridge. Tests wait on the `updates()` stream (no polling) to assert `.queued → .running → .done/.failed`, cancellation, and provisioning-failure paths.
