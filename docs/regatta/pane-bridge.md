# Pane Bridge — the Regatta ↔ cmux integration seam

> Issue #14. This is the **keystone seam** for Regatta worker management: every higher layer
> (Orchestrator #16, loop engine, condition checks) talks to a worker through this one boundary
> and nothing else. Keeping the boundary tiny is what keeps upstream cmux syncs cheap.

## What the Pane Bridge is

A **Pane Bridge** spawns a CLI coding-agent process at a given working directory, terminates it
and its pane cleanly, and exposes the agent's output as an observable stream for downstream
condition checks. It is defined as a protocol in `RegattaCore` so that *what* a worker needs from
a pane is decoupled from *how* a pane is realized.

```
┌─────────────────────────────────────────────┐
│ Orchestrator (#16), loop engine, conditions  │   depend only on `any PaneBridge`
└───────────────────────┬─────────────────────┘
                        │  PaneSpec  →  PaneHandle (id + AsyncStream<PaneOutputEvent>)
                        ▼
                 ┌──────────────┐
                 │  PaneBridge  │   protocol seam (RegattaCore)
                 └──────┬───────┘
          ┌────────────┴─────────────┐
          ▼                          ▼
 ┌──────────────────┐     ┌──────────────────────────┐
 │ ProcessPaneBridge│     │ (future) GhosttyPaneBridge│
 │  default, headless│     │  thin cmux-side adapter   │
 │  subprocess engine│     │  → visible Ghostty pane   │
 └──────────────────┘     └──────────────────────────┘
```

## The contract (`PaneBridge`)

```swift
public protocol PaneBridge: Sendable {
    func spawn(_ spec: PaneSpec) async throws -> PaneHandle
    func terminate(_ id: PaneHandle.ID) async throws
    func isRunning(_ id: PaneHandle.ID) async -> Bool
}
```

- **`PaneSpec`** — a pure `Sendable` value: `workingDirectory`, `executableURL`, `arguments`,
  `environment`. No live resources, so it can be built off-actor, logged, and replayed.
- **`PaneHandle`** — `id` (opaque `UUID` wrapper) + `output: AsyncStream<PaneOutputEvent>`.
- **`PaneOutputEvent`** — `.stdout(String)`, `.stderr(String)`, `.terminated(Int32)`. The stream
  finishes after exactly one `.terminated`, and **all output is delivered before it** (the default
  implementation waits for both pipes to drain before emitting the terminal event).
- **`PaneBridgeError`** — `.spawnFailed(String)`, `.unknownHandle(PaneHandle.ID)`.

Observation is an `AsyncStream`, never a callback or `NotificationCenter`, so downstream condition
checks iterate it deterministically (and tests can assert the exact event sequence).

## Why a protocol seam in RegattaCore (not a hook in cmux core)

This is the architecture decision the issue flagged as HITL. The chosen boundary is **a protocol
owned by RegattaCore with implementations plugged in at the app composition root**, for three
reasons:

1. **Minimal upstream touch points.** `RegattaCore` already builds and tests with zero cmux
   dependencies. Putting the contract here means the headless engine (`ProcessPaneBridge`) needs
   *no* cmux code at all, and a future Ghostty-backed bridge is a single new file that *consumes*
   cmux's existing `Workspace.newTerminalSurface(...)` / `closePanel(...)` API — it does not modify
   cmux's terminal layer. Upstream merges never conflict with the seam.
2. **Dependency inversion (cmux-architecture).** Higher layers depend on `any PaneBridge`, never a
   concrete pane. The app target is the one place a concrete bridge is named and injected.
3. **Headless testability.** The default implementation runs on CI with no AppKit, no Ghostty, and
   no real pane, driven by the `fake-agent.sh` harness (#10). The acceptance criteria
   (spawn/terminate/observe) are proven without launching the app.

## What ships now (AFK-complete)

`ProcessPaneBridge` — the default, host-independent implementation:

- **spawn** — `Process` with `currentDirectoryURL = spec.workingDirectory`, stdout/stderr pipes
  drained incrementally via `DispatchSource` read sources (the sanctioned low-level primitive,
  hidden behind the `AsyncStream`).
- **terminate** — kills the process *and* force-completes the stream even if a grandchild (e.g. a
  `sleep` the agent shell spawned) still holds a pipe write end open, so `terminate()` never hangs.
- **observe** — `handle.output` yields `.stdout`/`.stderr` chunks in arrival order, then one
  `.terminated(code)`.
- **isRunning** — lifecycle query for polling condition checks.

All mutable state lives in the actor; the one-shot completion guards use the cmux-architecture lock
carve-out (synchronous compare-and-set from non-async `Process`/`DispatchSource` callbacks).

## The remaining cmux touch point (needs Josh's sign-off)

A **visible** Ghostty pane (so a human can watch/take over a worker) requires one thin adapter in
the **app target** that conforms to `PaneBridge`:

| Bridge method | cmux API it would call |
|---|---|
| `spawn` | `Workspace.newTerminalSurface(inPane:workingDirectory:initialCommand:startupEnvironment:)` → returns a `TerminalPanel`; map its panel id to a `PaneHandle.ID`. |
| `terminate` | `Workspace.closePanel(_:force:)`. |
| observe | Tap the surface's PTY output. cmux exposes terminal contents/scrollback (e.g. `ghostty_surface_*` reads in `GhosttyTerminalView.swift`) but **not** a clean incremental output `AsyncStream` today — this is the one place that may need a small read seam added in cmux. |

**Open question for Josh:** for the visible-pane path, do we (a) add a minimal output-tap seam to
the cmux surface layer, or (b) run the agent under `ProcessPaneBridge` for observation and mirror
it into a Ghostty pane for display only? Option (b) keeps cmux untouched; option (a) is a single,
well-scoped read seam. The protocol means either choice is swappable without touching anything
above the seam.

## What this unblocks (#16)

The Orchestrator consumes exactly this surface — no more, no less:

```swift
let handle = try await bridge.spawn(
    PaneSpec(workingDirectory: worktree.path,
             executableURL: URL(fileURLWithPath: "/usr/bin/env"),
             arguments: ["claude", "--print", task],
             environment: env)
)
for await event in handle.output {
    // condition checks: detect markers, errors, completion → decide retry/stop
}
try? await bridge.terminate(handle.id)
```
