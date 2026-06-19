# Regatta

A fork of [cmux](https://github.com/manaflow-ai/cmux) that turns the terminal into a command deck for AI coding agents.

A persistent **brain** sits beside your normal work. Hand it a tab, a PR, or a task and it races a **fleet** of ephemeral agent terminals — each in its own git worktree, off in a separate space so they never clutter your workspaces. It **loops** them until a real exit condition is met (tests pass, CI green, the job is done), **shepherds** your PRs through CI failures and reviewer comments after you've moved on, and **compounds** everything it learns in a self-organizing memory tree.

Orchestration patterns are borrowed from [ARMADA](https://github.com/calumjs/ARMADA); the implementation is native Swift layered onto the cmux fork.

> **Fork baseline:** cmux @ `e85f1b6`. Upstream is tracked as the `upstream` git remote for selective updates. cmux is GPL-3.0-or-later; so is this fork.

## Pillars

- **Brain + fleet** — a controller agent that spawns and supervises worker subagents as real, watchable terminals.
- **Loops** — run an agent until a deterministic (or brain-judged) exit condition, with hard safety caps.
- **Memory** — a hierarchical, self-partitioning fact store with dedicated allocator + archivist agents. Auto-built, hand-correctable.
- **PR shepherding** — hand off a finished PR; Regatta watches CI and review threads and acts.

## Docs

- [`docs/regatta/design.md`](docs/regatta/design.md) — full design
- [`docs/regatta/cmux-architecture.md`](docs/regatta/cmux-architecture.md) — where Regatta hooks into cmux
- [`docs/regatta/theme.md`](docs/regatta/theme.md) — Blue Matrix base theme
- [`docs/regatta/BUILD.md`](docs/regatta/BUILD.md) — toolchain + build runbook (macOS)
- [`docs/regatta/cmux-upstream-README.md`](docs/regatta/cmux-upstream-README.md) — original cmux README

## Backlog

Work is broken into vertical-slice PBIs tracked as [issues](https://github.com/joshbermanssw/Regatta/issues), grouped by epic via milestones. Each is an independently grabbable tracer bullet with acceptance criteria.

## Build (short version)

Requires macOS + Xcode 26 (+ Metal toolchain), Zig 0.15.2, bun, rust, node. See [`docs/regatta/BUILD.md`](docs/regatta/BUILD.md) for full setup. Then:

```bash
./scripts/setup.sh                 # submodules + prebuilt GhosttyKit
./scripts/reload.sh --tag dev      # build (add --launch to open)
```

## Status

Baseline builds and launches. Building Regatta features from the backlog, milestone by milestone.
