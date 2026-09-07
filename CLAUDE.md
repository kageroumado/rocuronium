# Rocuronium

Drives a Mac's UI — reads the accessibility tree, clicks, types, captures the screen — **without taking the cursor or changing the frontmost app**, and returns evidence that the action actually happened. One signed `.app` holds the Accessibility grant and does all the work; a thin CLI and an MCP server speak to it over a unix socket.

This file is the map for working *on* the code. Grep the tree and read the source for detail; what follows is the shape and the invariants that aren't visible from any single file.

## Module map

```
Rocuronium/                     the .app (menu-bar daemon, holds TCC)
  App/            RocuroniumApp, MenuPopover, SettingsWindow, ModelSettingsView, DemoStage, Theme
  Control/        ControlServer (unix socket), CommandRouter (verb dispatch)
  Core/
    Engine.swift  the actor; all AXUIElement work lives behind it
    Perception/   AXElement, ElementQuery, MenuQuery, ScreenCapture, TextDump,
                  TreeCache, TreeDelta, FrameStore, FrameDiff, WebContent
    Actuation/    GhostReach (the ladder), EventPoster, HardwareInput, PathPlan
    Evidence/     Evidence (verdict), ScreenDiff
    Environment/  UserPresence, EmergencyStop, SessionContext, Foreground, DisplayWake,
                  AdrafinilBridge, VirtualDisplayManager, VirtualDisplayBridge, ParkLedger,
                  PresenceRelay, InputAttribution
    Plan/         SequencePlan, PlanExecutor, PlanGuard
  Vision/         GroundingBackend (protocol), MLXBackend, DetectorBackend,
                  FoundationModelsBackend, TextSighting
  Presence/       PresenceOverlayController, OverlayViews, HotkeyMonitor, ActivityLog,
                  ConsentView, MenuBarGlyph, + jelly art
RocuroniumCLI/    thin client: main.swift (CLI + `mcp` stdio server), MCPServer.swift
RocuroniumTests/  unit tests
```

**`Core/` must not import `App/` or SwiftUI** — the engine has to build and run headlessly and be reusable from the CLI path.

## Process model

The `.app` holds the Accessibility + Screen Recording grants and does all work; the CLI is a dumb pipe (JSON over a `SOCK_STREAM` unix socket, newline-delimited, one request-reply per connection). `rocuronium mcp` wraps the same socket in MCP stdio, exposing the verbs as typed tools.

- **Auth**: peer identity via `LOCAL_PEERTOKEN` (audit token, race-free) checked against a Developer ID team-OU anchor. Same-uid *and* signed by us.
- **Serialization**: the accept loop dispatches each request to the main actor via a semaphore-blocked task, bounded at 30 s; a timeout cancels the in-flight task rather than abandoning it (an abandoned hardware action would move the cursor for an agent that believes it failed). **One request at a time by construction** — `Engine` and `TreeCache` depend on it. Making the accept loop concurrent without making `Engine` reentrant corrupts `TreeCache` and interleaves cursor positions.

## The tentacle ladder

A "tentacle" is just a **level**: `GhostReach` tries to deliver an action by the least invasive means that works, and falls through to the next level only when a level fails. Each level is **verified before escalating** — a return code alone is never treated as success — and the reply reports which level acted and the evidence for it. Levels 0–3 never move the cursor or change the frontmost app; level 4 does and is opt-in per call.

| # | Level | Mechanism | Cursor | Focus | Verification |
|---|---|---|---|---|---|
| 0 | Display wake | IOPM assertion | — | — | woke / already awake / failed |
| 1 | Accessibility | `AXSetValue`, `AXPress` | No | No | read-back (text), window count (press) |
| 2 | Posted events | `CGEvent.postToPid` (unicode payload) | No | No | read-back (text), focus delta (click) |
| 3 | App automation | referral only (names refrax-ctl / CDP) | No | No | the named channel |
| 4 | Hardware ("the sting") | `CGEventPost` to the session tap | **Yes** | **Yes** | read-back, focus, pixel delta, occlusion pre-check |

Non-obvious fall-through rules:
- **Electron ignores keycode-only events** — editing ops (clear, select-all) go through level 1, never level 2, because Chromium reads the unicode payload but not bare keycodes.
- **`AXSetValue` returns `.success` on WebKit while changing nothing** — level 1 counts only after a read-back confirms it; otherwise it falls through.
- Level 4 is gated on `allowHardwareInput`, refused when the screen is locked (the console belongs to the password field) or when another window occludes the aim point (a real click hits whatever is topmost — parking the target on the virtual display satisfies the check).

## Evidence — the verdict is the contract

Every action returns an `Evidence` value; the verdict is *computed*, never asserted:

| Verdict | Meaning |
|---|---|
| `.confirmed` | read-back matches, or pixels changed in the target's rectangle |
| `.noEffect` | the call reported success but nothing observably changed (the WebKit case) |
| `.unverifiable` | no readable value and no pixel access — says so instead of claiming success |

Signals feeding the verdict: read-back (`element.value` after write), pixel delta (two captures of the element rect, banded >2% confirmed / <0.05% noEffect), window-count delta (dialogs/menus), process-exit (`kill(pid,0)==ESRCH`), focus delta, selection delta. Pixel evidence takes two consecutive captures with nothing between; if the window moves by itself above tolerance, pixels can't testify. **The whole system exists because the accessibility API routinely reports success while doing nothing** — never trust a return code as evidence.

## Perception and diffs

`read`/`find` walk or search the AX tree (bounded: 40 depth, 20k elements, 30k chars, 18 s; walks cached in `TreeCache` behind an O(1) fingerprint — focused element, window count, front title, display-awake — re-taken on every hit). `screenshot` is `ScreenCaptureKit` window capture (occlusion-proof). Every `read`/`screenshot` reply carries an observation `token`; passing it back as `--since` returns the delta — structural (`TreeDelta`) or pixel (`FrameDiff`). Both degrade honestly via `diffNote`; neither silently emits a wrong diff. Any truncation is reported, never silent.

## Presence and safety — two invariants

1. **Never take the cursor without opt-in.** Ghost tentacles are the default; hardware needs `allowHardwareInput` (click/type) or `confirm` (move/drag/activate). `UserPresence` reads HID idle, lock, and display power → present/idle/away/unknown, **defaulting to present when unknown**. Presence is *propagated to the agent* (a `mayTakeCursor` flag + advice), not acted on unilaterally.
2. **Every action returns evidence** (above).

`EmergencyStop` is a process-global atomic checked per-element in walks and per-sample (~8 ms) in cursor traces — ⌃⌥⇧⎢ halts mid-payload. **Resume is popover-only: no socket verb clears the halt**, so an agent cannot un-halt itself. `Core` never imports `Presence/`; the engine telegraphs hardware actions through `PresenceRelay`'s static hooks.

## Off-console / event tap

`SessionContext` detects on-console vs off-console (Screen Sharing, fast user switch). Off-console, `HIDIdleTime` reports the *console* user's hands, "screen locked" means no viewer is attached, and events **must** post to `.cgSessionEventTap` — posting to `.cghidEventTap` off-console moves the console user's cursor (measured). Every `HardwareInput` post site is gated by `SessionContext.eventTap`.

## Virtual display

`VirtualDisplayManager` creates a `CGVirtualDisplay` in-process (private API via a bridging header), positioned right of the main display, asserting it never becomes primary. `VirtualDisplayBridge` models it as a refcounted **lease** (explicit or auto, the latter taken by `park`); `ParkLedger` records each window's `before` frame. **Teardown always sweeps parked windows home first** — a display torn out from under a window strands it. Creation failure degrades to "isolation unavailable", never a crash.

## Sequence plans

A plan is a JSON step list, not a program: `PlanExecutor` runs steps sequentially via `CommandRouter.dispatch()` with `PlanGuard` postconditions between them (`verdict`, `readback-contains`, `window-appears/vanishes`, `text-visible/vanishes`) and four failure policies (`abort`, `continue`, `pause-for-human`, `fallback`). Branching beyond those stays with the calling agent. The reply is one transcript blob.

## Build / test loop

- **Debug is build-sign-install**: the socket verifies the peer's Developer ID signature, so an unsigned `.build/debug` binary is refused. Run `./Scripts/install.sh` (builds + signs the bundle, no version bump, notarization skipped), then use `/Applications/Rocuronium.app/Contents/Resources/rocuronium`.
- **The embedded CLI lives in `Contents/Resources`, never `Contents/MacOS`** — the filesystem is case-insensitive and `rocuronium` there would overwrite the app's own `Rocuronium` executable.
- **A command or flag change lands in four places**: the router's `dispatch`, the CLI `usage`, `MCPServer.tools`, and the guide. `DocsConsistencyTests` proves the first three stay in sync — add a verb to the router and to its `commands` set or the build fails.

## Non-goals

The agent loop (the calling harness owns it), a scripting DSL (the CLI is the DSL), cloud, cross-platform, and Mac App Store distribution (the entitlements make MAS impossible). **Auto-unlock is explicitly declined**: a locked session with an awake display already exposes full AX trees, so the engine works through a lock without ever entering credentials, installing a SecurityAgent plugin, or touching the authorization database. A lock software can talk its way past is not a lock.
