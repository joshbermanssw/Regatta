# RegattaCore

RegattaCore is the foundational backend package for the Regatta feature (parallel AI-agent orchestration inside cmux). It provides `RegattaWorktreeManager` — an actor that provisions and cleans up isolated git worktrees for parallel workers — along with `RegattaWorktree` (the value record a worktree returns) and `WorktreeError` (the error enum). The package's tests include the `FakeAgent` harness that drives `fake-agent.sh` via `Process`, exercising the same subprocess spawn path used by the real orchestrator. Tests run headlessly via `swift test` (no app host required), which is the whole point: subprocess-spawning tests that previously hung inside the cmux app-host test runner now execute reliably in SwiftPM's own runner.

## Pane Bridge

RegattaCore also owns the **Pane Bridge** — the single, minimal integration seam between Regatta worker management and the host's pane/terminal layer (issue #14). It is a protocol so higher layers depend only on the contract, never on a concrete pane:

- `PaneBridge` — `spawn(_:)` / `terminate(_:)` / `isRunning(_:)`.
- `PaneSpec` — pure value describing the agent process (cwd, executable, args, env).
- `PaneHandle` — opaque `id` + `output: AsyncStream<PaneOutputEvent>`.
- `PaneOutputEvent` — `.stdout` / `.stderr` / `.terminated(code)`; the stream finishes after one `.terminated`, with all output delivered first.
- `ProcessPaneBridge` — the default, host-independent implementation that runs the agent as a subprocess and streams its output incrementally. It needs no cmux/Ghostty/AppKit code, so it is what the fake-agent harness and headless CI use.

A future cmux/Ghostty-backed bridge conforms to the same `PaneBridge` protocol; the documented integration boundary (including the open question for the visible-pane path) lives in `docs/regatta/pane-bridge.md`.

Example:

```swift
let bridge: any PaneBridge = ProcessPaneBridge()
let handle = try await bridge.spawn(
    PaneSpec(workingDirectory: worktree.path,
             executableURL: URL(fileURLWithPath: "/usr/bin/env"),
             arguments: ["claude", "--print", task])
)
for await event in handle.output { /* condition checks */ }
try? await bridge.terminate(handle.id)
```
