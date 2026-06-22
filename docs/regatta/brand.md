# Regatta — Brand Identity

> The command deck for AI coding agents. Hand off the work; a **brain** races a
> **fleet** to the finish line and **shepherds** it home.

This is the canonical brand reference for Regatta. It extends the
[Blue Matrix base theme](./theme.md) into a full identity: mark, color,
type, voice, and the nautical lexicon the product is built on.

---

## 1. Essence

**Personality: Command Deck.** Precise, calm under pressure, in command — a race
committee running a fleet, not a hacker at a terminal. Regatta is the operator's
post: you delegate, it dispatches, you watch the fleet land.

Three words: **precise · calm · in command.**

**Tagline (primary):** *Hand it off. Watch it land.*

Alternates, in order of preference:
- *Race the fleet. Ship the work.*
- *Your fleet, under command.*

One-line positioning: *Regatta turns the terminal into a command deck — a
persistent brain that races a fleet of agent terminals to a real finish line and
shepherds your PRs home.*

---

## 2. Logo & mark

The mark is a **fleet of sails**: one bold **lead sail** (the brain) ahead of two
trailing sails (the fleet), sitting on a **waterline**, drawn with nautical-chart
precision — clean triangles, exact angles, no flourish. A small **burgee
(pennant) at the lead masthead glows Wake Green** = the live signal that the fleet
is racing. The descending sail sizes also read as a command hierarchy: one leads,
the rest follow.

### Assets
| File | Use |
|---|---|
| [`design/brand/regatta-mark.svg`](../../design/brand/regatta-mark.svg) | Full-color mark (transparent) |
| [`design/brand/regatta-mark-mono.svg`](../../design/brand/regatta-mark-mono.svg) | Single-color (`currentColor`) for one-ink contexts |
| [`design/brand/regatta-wordmark.svg`](../../design/brand/regatta-wordmark.svg) | Horizontal lockup: mark + "Regatta" |
| [`design/brand/regatta-icon.svg`](../../design/brand/regatta-icon.svg) | Square app icon on Deck Black |
| [`design/brand/palette.svg`](../../design/brand/palette.svg) | Color swatch sheet |

### Construction & spacing
- The mark is built on a 128-unit grid; sails share a single waterline.
- **Clear space:** keep padding equal to the height of the burgee (≈ 1/8 of the
  mark height) on all sides. In the icon, the mark sits in the central ~60%.
- **Minimum size:** mark legible to 16px; below that, drop the rear sail's wake
  tick and the secondary waterline. The wordmark should not be used below 20px
  cap height — use the mark alone.

### Don't
- Don't recolor the burgee anything but Wake Green — it is the live signal.
- Don't add a third+ trailing sail, rotate the fleet, or tilt the waterline.
- Don't place the full-color mark on busy or light backgrounds without the mono
  variant.
- Don't stretch, add drop shadows, or outline the wordmark text manually (outline
  to paths instead).

---

## 3. Color

Extends Blue Matrix. **Azimuth Blue** is the primary brand color (a deeper,
saturated azure replacing the old `#00a2ff`). Wake Green is reserved for *live /
active* states — it is a signal, not decoration.

| Token | Hex | Role |
|---|---|---|
| **Azimuth Blue** | `#1E90FF` | Primary brand · brain · links · active |
| **Wake Green** | `#00FF9C` | Live · running · "go" signal (use sparingly) |
| **Deck Black** | `#101116` | Canvas / app background |
| **Panel** | `#15171E` | Raised surfaces (the rail, cards) |
| **Caution** | `#FFFC58` | Queued / warning |
| **Foul Red** | `#FF5680` | Failed / error |
| **Hull White** | `#FFFFFF` | Foreground text on dark |
| **Fog** | `#686868` | Muted text / disabled |

Supporting tints (from the Blue Matrix ANSI palette) for gradients and charts:
`#3DA0FF` (light azure), `#6871FF` (indigo), `#76FF9F` (cursor green).

**Usage rules**
- Default surface is Deck Black; raise panels to Panel, never lighter.
- Azimuth Blue carries identity and interaction. Wake Green means *something is
  alive right now* (worker running, loop progressing) — if everything is green,
  nothing is.
- Map state colors consistently: running = Wake Green, queued = Caution,
  failed = Foul Red, done = Hull White (checkered-flag iconography).

---

## 4. Typography

| Role | Typeface | Notes |
|---|---|---|
| Display / wordmark / headings | **Space Grotesk** (600/500) | Precise, slightly nautical. Tight tracking (-1 to -2). |
| UI / body | **Inter** | Workhorse. 400/500/600. |
| Code / terminal / data | **JetBrains Mono** | The terminal is the product; mono carries logs, IDs, metrics. |

All three are open-licensed. System fallbacks: `-apple-system` (UI),
`ui-monospace`/`SF Mono` (code). Production wordmark and icon text must be
outlined to paths so they render without the font installed.

---

## 5. Voice & tone

An **operator's log**: terse, nautical, exact. Verbs of command and arrival —
*hand off, dispatch, race, loop, shepherd, land*. Confidence without hype; the
fleet does the work, the copy just reports it.

- **Sentence case** in UI labels and prose. **lowercase** in CLI and system
  lines (`> regatta · fleet racing (3)`).
- Short declaratives over marketing adjectives. "Shepherding PR #82." not
  "Intelligently monitoring your pull request!"
- Use the lexicon below precisely and consistently. A worker is never an
  "instance"; a loop is never a "retry job".

| Say | Not |
|---|---|
| Hand it off | Delegate the task |
| The fleet is racing | Agents are processing |
| Shepherding PR #82 | Watching the PR |
| Landed | Completed successfully |
| Foul (failed leg) | Error occurred |

---

## 6. Lexicon (the nautical model)

The product's vocabulary is the brand. Each term maps a Regatta concept to its
nautical logic — use these names everywhere (UI, code, docs, copy).

| Term | What it is | Why the name |
|---|---|---|
| **Brain** | The persistent controller agent beside your work. | The mind on the command deck directing the race. |
| **Fleet** | The set of worker terminals the brain races. | A regatta is a fleet of boats racing at once. |
| **Worker** | One ephemeral agent terminal in its own git worktree. | A single boat in the fleet, crewed and racing. |
| **Loop** | Running a worker until a real exit condition is met. | Sailing the legs of a course until you cross the line. |
| **Shepherd** | A persistent watcher that nurses a PR through CI and review after handoff. | Escorting a boat safely into harbor. |
| **Memory** | The self-organizing, hierarchical fact store. | The ship's log and charts — what the fleet has learned. |
| **Summon** | Calling the brain to the foreground to hand it work. | Hailing the command deck. |
| **Handoff** | Giving the brain a tab, PR, or task to take over. | Passing the helm. |

---

## 7. Iconography & state signals

Thin-line nautical-instrument set: 1.5px stroke, built from sails, flags,
compass, and course-marks. Consistent with the mark's chart-precise geometry.

State signals (used in the rail, fleet grid, toasts):

| State | Signal | Color |
|---|---|---|
| Running / live | green pennant (burgee) | Wake Green `#00FF9C` |
| Queued / waiting | amber course-mark | Caution `#FFFC58` |
| Failed / foul | red foul flag | Foul Red `#FF5680` |
| Landed / done | checkered flag | Hull White `#FFFFFF` |

---

## 8. Asset index

All brand assets live in [`design/brand/`](../../design/brand/). The base terminal
theme they derive from is documented in [`theme.md`](./theme.md). When the app
icon ships, generate it from `regatta-icon.svg` into `AppIcon.icon` / the
`.icon` asset.
