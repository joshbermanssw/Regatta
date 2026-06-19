# Regatta — a cmux fork for agent orchestration, loops & memory

**Date:** 2026-06-19
**Status:** Design — approved sections, pending final spec review
**Working name:** Regatta (the new module inside the cmux fork)

## 1. Goal

Fork [`manaflow-ai/cmux`](https://github.com/manaflow-ai/cmux) (the native macOS, Swift/AppKit + Ghostty terminal for AI coding agents) and bake in a dedicated **agent-orchestration + looping + memory** surface — so this lives in its own clean UI rather than bleeding into normal coding work.

The orchestration *patterns* are borrowed from [ARMADA](https://github.com/calumjs/ARMADA) (Crows-Nest parallel scheduling, loop-until-dry, worktree isolation, Cartographer-style learned heuristics). ARMADA is a set of Claude Code *skills*, not an importable library, so we **reimplement its patterns** in the fork rather than linking its code.

## 2. Scope

**In:**
- A persistent **Regatta brain** (controller agent) always available beside normal work.
- Attaching tabs/PRs/PBIs to the brain as context.
- The brain spawning **ephemeral worker subagents** as real, watchable terminals in a **separate space**.
- **Loops**: run a worker until a defined exit condition, with hard safety caps.
- **Memory**: a self-organizing hierarchical fact store with Allocator + Archivist agents.
- **PR handoff / shepherding**: hand a finished PR to Regatta; it watches CI and reviewer threads and acts.

**Out (deliberately):**
- GitHub **issue** triage / auto-creation (ARMADA's Charter/Crows-Nest issue side). PR-level integration only.
- The full seven-skill ARMADA fleet as separate skills.
- Multi-process sidecar daemons — everything is in-app native Swift + spawned CLI agents.

## 3. Architecture

**Fork base:** `manaflow-ai/cmux` — native macOS, Swift/AppKit, Ghostty terminal surface. The orchestration UI is built natively in that stack.

**New module:** `Regatta` — a Swift module sitting *beside* cmux's existing terminal/pane code, reusing it (not replacing it).

**What an agent is:** Agents are **CLI coding-agent processes running in Ghostty panes**, wrapped by the native Regatta engine.
- **Brain** = a persistent **Claude Code** session (ARMADA-derived patterns/skills loaded) living in the right rail.
- **Workers** = CLI agent processes spawned into panes inside git worktrees. **Default Claude Code (Opus), swappable per worker** (Codex/Gemini), since cmux is already agent-agnostic.
- **Memory agents** (Allocator, Archivist) = same kind of process, specialized prompts.

The native engine never reimplements an agent — it **wraps stock CLI agents** to add orchestration, deterministic loop control, memory injection, and worktree/space management.

### Components (native Swift)

| Component | Responsibility |
|---|---|
| **Orchestrator** | Scheduler/fleet owner: queue jobs, enforce concurrency cap, assign worktrees, spawn/kill agent processes. |
| **Loop Engine** | Wrap a worker run in iterate-until: re-prompt, count, evaluate exit conditions, continue/stop/fail. |
| **Condition Evaluators** | Pluggable checks: tests pass · cmd exits 0 · output matches · N iterations · dry · manual · **LLM-judged ("brain decides done")**. |
| **Memory subsystem** | Hierarchical store + Allocator (recall) + Archivist (storage/curation). |
| **PR Shepherd** | Long-lived per-PR watcher: poll CI + review threads, dispatch reactive workers. |
| **Pane Bridge** | Adapter onto cmux's Ghostty surface spawn + I/O, so every agent runs in a real pane. |
| **State Store** | In-memory source of truth + on-disk persistence (session restore). |
| **Fleet UI** | The right-rail surface + summon overlay + loop/memory/PR views. |

### Entity model

| Layer | What it is |
|---|---|
| Workspaces / tabs | Normal work. Untouched. Attachable as context. |
| Regatta brain | Persistent controller you talk to; decides & delegates. |
| Worker subagents | Ephemeral terminals doing the actual work, in the separate space. |
| Memory agents | Allocator (recall) + Archivist (storage). |
| Memory store | Persistent hierarchical facts/heuristics — the part that compounds. |
| PR shepherds | Long-lived event-driven watchers tied to a PR. |
| Native Fleet engine | Swift machinery wrapping it all. |

### Data flow

Attach tab/PR to brain → brain plans → Orchestrator queues → assigns worktree → Pane Bridge spawns CLI agent in a Ghostty pane → Loop Engine watches output + runs Condition Evaluators per iteration → Allocator injects recalled memory at start, Archivist writes facts as work happens → State Store updates → Fleet UI re-renders.

## 4. UI — Layout C (right rail + summon overlay)

The brain is always glanceable in a **right rail** beside real work; ephemeral terminals are **summoned** as an overlay grid over the main area and dismissed with `esc`. This keeps ephemeral agents out of normal workspaces while the brain stays with you.

**Rail sections (top→bottom):**
1. **⚓ Regatta (brain)** — status (idle/thinking/N running), chat, input with a **`＋ attach tab`** affordance (how a tab's repo/PR/PBI context is passed in).
2. **Fleet** — live workers; each shows a status dot (running/queued/done) and a **loop badge** (`↻3 · tests` = iteration + exit condition).
3. **🌳 Memory** — the inferred tree with per-node counts and `+ new partition`.

**Summon overlay:** click a worker (or expand) → workers fill the main area as a grid of **real, typeable terminals**, with a `＋ spawn worker` tile; `esc` returns to work, brain stays in rail.

### Loop view (opens from a `↻` badge)
- **Goal** the worker keeps retrying.
- **Exit condition** chips: tests pass · cmd exits 0 · output matches · N iterations · dry · manual · LLM-judged — plus the actual **check command**.
- **Safety caps**: max iterations + token budget (loops can't run away).
- **Iteration history**: each pass with result + a one-line "what it did/learned", counted `n / cap`.
- **Controls**: pause · jump into terminal (human takeover mid-loop) · edit goal/condition · stop.

### Memory inspector (auto-built, hand-correctable)
- **Tree** auto-built; Archivist creates sub-nodes on its own (e.g. a `billing` node from a PR).
- **Facts** per node with **provenance** (which worker, when, which PR) and a **type** (heuristic / preference / fact).
- **Inherited facts** shown dashed with `↧ override here`.
- **Per-fact controls**: pin · move to parent · edit · delete.
- **Allocator preview**: exactly what would be injected for a scope (local + inherited, token estimate) — recall is never a black box.
- **Conflict policy**: Archivist **auto-supersedes** stale facts, keeping the old value in history.

### PR shepherd
- **🛡 PR #N** = long-lived watcher in the fleet.
- **CI/CD watch** as a loop (`↻ until checks green`); on failure wakes a `ci-fix` worker to diagnose + push retry.
- **Review threads** each handled: code change + push, reply, resolve.
- **Activity log** of actions taken while away.
- **Per-PR autonomy toggle**: `auto-push & resolve` vs `stage for my approval`.

## 5. Memory subsystem detail

- **Hierarchical, inferred namespace** (e.g. `Tina ▸ TinaCMS ▸ billing`). Not flat, not fixed-depth.
- **Archivist** classifies each fact to a node, **creating partitions** when a new scope appears; dedupes and curates.
- **Allocator** resolves active scope from the attached tab's signals (git remote/org, repo, path, PR) and injects the node's facts **plus inherited ancestors**, within a context budget.
- **Inheritance**: umbrella facts apply to all descendants; project facts stay local; locals can override inherited.
- **Auto but inspectable**: full tree visible; facts re-parentable / pinnable / editable / deletable.
- **Persistence**: facts stored as structured records on disk (frontmatter-style: type, scope path, provenance, timestamps, supersedes-history).

## 6. PR handoff / shepherding detail

- **Trigger mechanism: polling via `gh`** (~30–60s lag, fully local, no infra). No webhooks/GitHub App in v1.
- **CI watch**: poll checks; on failure spawn a worker looping `until checks green` (capped).
- **Review threads**: poll for new comments; per thread, spawn a worker to address (code + push) and/or reply, then resolve.
- **Autonomy default**: new handoffs start **stage-for-approval**; user flips to full-auto per PR once trusted. Outward-facing actions (push, reply, resolve) are gated by this setting.

## 7. State & persistence

- **State Store** = in-memory source of truth, mirrored to disk under the fork's app-support dir.
- Persisted: fleet + worker definitions, loop configs + iteration history, memory tree + facts, PR shepherd watchers + autonomy settings, worktree assignments.
- **Session restore** rebuilds the rail/fleet view; like upstream cmux, **live process state is not resumed** (active CLI agent sessions don't survive restart) — workers show as `interrupted` and can be relaunched. PR shepherds (event-driven, stateless between polls) **do** resume.

## 8. Error handling

- **Agent process crash** → worker marked `failed`, last output retained, brain notified; loop counts the crash as a failed iteration (subject to cap).
- **Loop runaway** → hard stop at max-iterations or token-budget; surfaced in loop view.
- **Git worktree conflicts** → worker isolated per worktree; merge/rebase failures surface as a blocked worker for human resolution.
- **`gh` auth / rate limits** → PR shepherd pauses, shows an auth/ratelimit banner, retries with backoff.
- **CI never goes green** → loop hits cap, shepherd flips to `needs attention`, stops auto-pushing.
- **Outward-facing action failures** (push/reply/resolve rejected) → logged, surfaced, never silently retried in full-auto without backoff.

## 9. Testing strategy

- **Native engine unit tests** (Swift): Orchestrator scheduling/concurrency, Loop Engine state machine, each Condition Evaluator, memory tree classification/inheritance/override/conflict-supersede.
- **Pane Bridge** tested against a fake agent process (scripted stdout) so loop/condition logic is verified without real LLM calls.
- **PR Shepherd** tested against a mocked `gh` layer (recorded fixtures for checks + review threads) covering: CI red→fix→green, new comment→address→resolve, auth failure, never-green cap.
- **Memory** golden tests: a sequence of facts produces an expected tree + Allocator injection set.
- **Manual/integration**: real Claude Code worker in a scratch repo running a real loop-until-tests-pass.

## 10. Milestones (rough sequence)

1. Fork builds & runs; `Regatta` module skeleton + right rail shell (brain chat over a CLI Claude Code session).
2. Pane Bridge + Orchestrator: brain can spawn/kill a worker in a worktree, shown in fleet + summon overlay.
3. Loop Engine + Condition Evaluators + loop view.
4. Memory subsystem (store, Allocator, Archivist, inspector).
5. PR Shepherd (polling, CI loop, review threads, autonomy toggle).
6. Persistence/restore + error-handling polish.

## 11. Open questions / risks

- **Fork maintenance burden**: tracking upstream cmux changes against a growing native module. Mitigation: keep `Regatta` as an additive module with a thin, well-defined seam into cmux's pane API.
- **Brain reliability for orchestration**: the brain is an LLM; orchestration *decisions* are non-deterministic. Determinism is preserved only in the native loop/condition layer — keep all hard guarantees there, not in brain prompts.
- **`gh` polling latency/limits** at scale (many shepherded PRs) — may later justify webhooks/GitHub App (explicitly deferred).
- **Provider-swappable workers**: condition checks must be agent-agnostic; verify the Pane Bridge output-watching works for Codex/Gemini, not just Claude Code.
- **Memory drift**: even with auto-supersede, long-lived trees may accumulate cruft — may need a periodic Archivist "compaction" pass (not in v1).
