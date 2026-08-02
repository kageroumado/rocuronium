# rocuronium

**rx no. ??? ・ ro·cu·ro·ni·um /ˌroʊkjʊˈroʊniəm/ ・ a neuromuscular blocker for your cursor ♡**

*Design draft, 2026-08-02. Successor in spirit to Peekaboo; nothing shared but the goal.*

> Rocuronium is the rapid-onset neuromuscular blocker — the body goes still in about sixty
> seconds while everything else keeps working. That is the entire product: **the agent acts,
> the cursor never moves, and you never lose your hands.**

Alternates if the name doesn't land: **vecuronium** (intermediate-acting), **atracurium**
(self-degrading via Hofmann elimination — nice for ephemeral automation), **tubocurarine**
(the original arrow poison, but a mouthful).

---

## Why remake instead of patch

Peekaboo is **2,475 Swift files / 531k lines** and was designed before any of what we now
know. Three things are wrong at the architecture level, not the bug level:

1. **It drives the real cursor.** Every action fights the human for the one shared pointer.
2. **Actions don't return evidence.** "Is it working?" is unanswerable because a click reports
   that it was *sent*, not that anything *happened*.
3. **It trusts the accessibility tree.** Measured today: the tree lies (see
   `~/Developer/Experiments/ghost-input/RESULTS.md`).

A remake is smaller, not bigger: the ghost ladder plus verification is a few thousand lines.
Most of Peekaboo's mass is an agent runtime we no longer need — Claude Code *is* the runtime.

## The two invariants

Everything else is negotiable. These are not:

1. **The human keeps the cursor.** Real HID events are the last rung and are opt-in per call.
2. **Every action returns evidence.** Not a status code — a read-back value, a focused-element
   dump, or a before/after screenshot diff. `success` is not evidence; today WebKit returned
   `.success` from `AXSetValue` while changing nothing.

## Architecture

```
rocuronium-daemon   always-on, owns the ghost ladder, presence state, screen cache
      │
      ├── rocuronium CLI        one binary, scriptable, JSON out
      ├── MCP server            same verbs, for Claude Code / Rasagiline
      └── presence overlay      a visible mark while the agent is driving
```

**Perception is fused, never single-source.** AX tree *plus* `kAXFocusedUIElement` *plus*
pixels. Measured justification: Discord reports **zero** editable elements in a full tree walk,
yet its message box exists and is reachable through the focused-element query. A tool that only
walks the tree concludes "this app has no text fields" and is wrong.

**Actuation is the ghost ladder**, tried in order, each rung verified before falling through:

| rung | mechanism | works on |
|---|---|---|
| 0 | ensure display awake | **precondition — skip it and everything below silently fails** |
| 1 | `AXUIElementPerformAction` / `AXSetValue`, then read back | AppKit, Electron (focused element) |
| 2 | `CGEvent.postToPid` with a **unicode payload** | AppKit, Electron |
| 3 | app's own automation (`refrax-ctl`, WebDriver) | WebKit/Chromium page content |
| 4 | real HID `CGEventPost` — moves the cursor, requires explicit opt-in | everything else, games |

Rung 2 caveat, measured: **Electron ignores keycode-only events.** Backspace and Cmd+A posted
to Discord did nothing while unicode text worked, because Chromium reads the unicode string.
Clearing a field is a rung-1 operation, not a rung-2 one.

## Integration — the suite as one system

This is where a remake beats a fork: the pieces already exist and are yours.

- **adrafinil** — already a daemon + CLI + MCP with refcounted `acquire`/`release` driven by
  agent hooks. Rocuronium should call it instead of shelling out to `caffeinate`.
  **Gap found today: Adrafinil holds the *system* awake but lets the *display* sleep — which is
  exactly the state that collapses every AX tree.** Its correct behavior for quiet overnight
  work is the blindness case for UI work. Needs a display-class assertion
  (`adrafinil acquire --display`, `IOPMAssertionDeclareUserActivity`). **Small change, high
  value, and it makes Adrafinil the only wake-manager that understands agents that look.**
- **dantrolene** — owns lock policy and already exposes display-sleep controls. Rocuronium
  should defer to it rather than duplicating. Worth publishing the finding it validates:
  *lock is harmless to agents, display sleep is not.*
- **Test Display.app** — park driven windows on the virtual screen for full isolation: nothing
  the agent does is visible or reachable on the main display.
- **rasagiline** — the cockpit. Presence indicator, live action log, canvases. Rocuronium
  reports; Rasagiline renders. No UI duplication.

## Deliberately not built

The agent loop (Claude Code owns it), a scripting DSL (the CLI is the DSL), cloud anything,
and Windows/Linux. Vision grounding is a **pluggable backend**, not a dependency — local
UI-TARS/Holo1 via MLX when installed, plain screenshots to the calling model otherwise.

## Milestones

1. **Ghost core** — daemon + CLI with rungs 0–2 and mandatory read-back. Ports directly from
   `ghostprobe.swift`, which already implements and verifies all of it. (~1 week)
2. **Presence + evidence** — overlay while driving, JSON evidence on every call. (~3 days)
3. **Adrafinil display assertion** — the one-flag change above, shipped in Adrafinil. (~1 day)
4. **Perception fusion** — tree + focused element + screenshot, with a lying-tree fallback.
5. **MCP surface** — replace `mcp__peekaboo__*` in daily use, then delete the old dependency.

Milestone 1 is the whole thesis; if it feels good in daily use, the rest follows.
