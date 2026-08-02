# Handoff Summary

## Active Task

Build **rocuronium** (`~/Developer/rocuronium`) — a macOS menu bar app that lets an AI agent
drive this Mac **without taking the cursor or stealing focus**, and that **proves** what it did
rather than reporting a return code.

## Recent User Request

Ongoing since the session's start: design and build the app (a from-scratch replacement for
Peekaboo), then "spawn a reviewer agent… cross-check with what codex is doing… see if there are
hidden traps", then "properly sign and notarize all builds", then work through the review
findings. Most recent: fix the main-actor isolation issue, then the `TreeCache` fingerprint.

## Work Completed This Session

- **Measured the ground truth first** (`~/Developer/Experiments/ghost-input/`, `ghostprobe.swift`
  + `RESULTS.md`). Key findings, all reproduced:
  - **Display sleep collapses every accessibility tree** to the app element; screen *lock* does
    not. This is why agents can work on a locked Mac. `caffeinate -d` does not wake a sleeping
    display; declaring user activity does.
  - `AXSetValue` returns `.success` on WebKit content **while changing nothing** — a return code
    is never evidence.
  - Electron fields sit ~23 levels deep in a ~5,300-element tree; a 12-level walk reports
    "this app exposes nothing".
  - Chromium reads the **unicode payload**, not the keycode: `postToPid` keycode-only events
    (Backspace, Cmd+A) do nothing in Electron.
  - `postToPid` **does** reset `HIDIdleTime` (47 s → 627 ms), so the engine's own typing makes
    it look like a human is present. Re-verified under control after a reviewer disputed it.
- **Built the app**: engine (`Core/`), control socket + CLI (`Control/`, `RocuroniumCLI/`),
  menu bar UI, evidence system. Full design in `ARCHITECTURE.md`, positioning in `DESIGN.md`.
- **Signed + notarized** via `Scripts/release.sh` (Developer ID, hardened runtime,
  `kagerou-notary` profile, stapled; Gatekeeper reports "Notarized Developer ID").
- **Cross-checked OpenAI Codex** — source (`Docs/PRIOR-ART.md`) and disassembly of the shipped
  binaries (`~/Developer/Research/codex-computer-use-internals.md`). Their open repo has **no**
  GUI automation; the real implementation is a closed bundled plugin. Their
  `allow_locked_computer_use` is a full **auto-unlock** system (SecurityAgent plugin, root
  installer rewriting the auth DB) — **explicitly declined as a non-goal**, see ARCHITECTURE §11.
- **Reviewed and fixed** — see `Docs/REVIEW-2026-08-02.md` for the full list with severities.

## Current State

Everything works end to end on the signed build: `find --app Discord` returns fields at depth
21–24 of ~7,600 elements; `type` lands text confirmed by read-back with the cursor untouched.
Last action was hardening the `TreeCache` fingerprint (commit `489abaf`); verified the common
case still caches (two consecutive finds → 0 hits, then 1).

## Files Modified/Created This Session

- `Rocuronium/Core/Engine.swift` — **actor** owning all AX work; the isolation boundary
- `Rocuronium/Core/Perception/` — `AXElement`, `ElementQuery`, `TreeCache`, `ScreenCapture`
- `Rocuronium/Core/Actuation/` — `GhostLadder` (the rung ladder), `EventPoster`
- `Rocuronium/Core/Evidence/` — `Evidence` + `Verifier`, `ScreenDiff`
- `Rocuronium/Core/Environment/` — `DisplayWake`, `UserPresence`, `InputAttribution`,
  `VirtualDisplayBridge`
- `Rocuronium/Control/` — `ControlServer` (unix socket, signature-checked), `CommandRouter`
- `Rocuronium/RocuroniumApp.swift` — menu bar app, permission buttons, `LSUIElement`
- `RocuroniumCLI/` — thin client, no permissions, no AX code
- `Scripts/release.sh` — build → sign → notarize → staple → install
- `Docs/` — `REVIEW-2026-08-02.md`, `PRIOR-ART.md`, `HANDOFF.md`

## Pending Tasks

1. `VirtualDisplayBridge` leases are **not refcounted** — two holders can tear the display out
   from under each other; `release()` also doesn't clear `startedByUs` when the app died on us.
2. `VirtualDisplayBridge` and the `Vision/` backends are **wired to nothing** — no command
   acquires a display or uses a grounding model.
3. **Rung 3 (app automation)** is a stub: WebKit/Chromium page content is unreachable by OS
   input and needs `refrax-ctl` / CDP adapters.
4. **Rung 4** is declared but not implemented (`EventPoster` has no hardware-input path).
5. Element **re-fetch after invalidation** (Codex ships `RefetchableSkyshotAXTree`); and their
   trick of pressing **menu items** via `AXMenuItemCmdVirtualKey` would give Electron the
   shortcuts `postToPid` can't deliver.
6. **Screen Recording is still ungranted** — optional, only upgrades unverifiable click
   verdicts. `CGRequestScreenCaptureAccess` won't prompt; suspect launch-context/TCC.
7. MCP server surface; `adrafinil acquire --display` (Adrafinil holds *system* sleep only).

## Important Context

- **Debug loop is build-sign-install.** The socket now verifies the peer's code signature
  (`anchor apple generic and certificate leaf[subject.OU] = "52K336H235"`, checked against the
  audit token). `./RocuroniumCLI/.build/debug/rocuronium` is **refused** — correctly. Use
  `./Scripts/release.sh --install`, then
  `/Applications/Rocuronium.app/Contents/Resources/rocuronium`.
- **Do not put the CLI in `Contents/MacOS/`** — the filesystem is case-insensitive, so
  `rocuronium` overwrites the app's own `Rocuronium` executable. It lives in `Contents/Resources`.
- **Never trust a return code**; every action reads back. Verdicts are `confirmed` / `noEffect` /
  `unverifiable`, and a weak pixel signal must stay `unverifiable` — claiming `noEffect` makes an
  agent retry something that worked.
- **Attribute invariance honestly**: only `hardwareInput` can move the cursor, so movement under
  any other rung is the *user's* hand. A warning that fires on unrelated activity trains people
  to ignore the one that matters.
- Module default isolation is **MainActor**; engine types are explicitly `nonisolated`, and
  `AXUIElement` is **not** `Sendable`, so elements must never leave `Engine`.
- Kiri's rules: **never `rm`** (use `trash`, a hook enforces it); no comments inside Bash tool
  commands; US English; commit with her normal git identity (no `-c user.email`).

## Continuation Instructions

Start with **pending item 1** (`VirtualDisplayBridge` refcounting) — it is small, self-contained,
and the last known correctness bug. Give it a `Set<UUID>` of outstanding leases and tear the
display down only when it empties; set `startedByUs` immediately after `openApplication` returns
and clear it unconditionally in `release()`.

Then **item 2**: wire the virtual display to a real command (`--isolated` on `type`/`click`), so
the lease machinery is exercised rather than theoretical.

Before changing behavior, read `Docs/REVIEW-2026-08-02.md` — it records what was measured, what
two reviewer claims did **not** reproduce, and why each fix is shaped the way it is.
