# rocuronium — architecture

*How the app is organized, why each boundary exists, and what every decision was measured
against. Findings referenced here live in `~/Developer/Experiments/ghost-input/RESULTS.md`.*

---

## 1. Process shape — the app *is* the daemon

Adrafinil needs three processes (app, daemon, privileged helper) because it manipulates system
power state. Rocuronium needs **one**, for a reason that decides the whole design:

**Accessibility permission is granted to a bundle, not to a binary.** Every AX read, every
`postToPid`, every screen capture must run inside the signed `Rocuronium.app`, which holds the
TCC grant. A standalone CLI would need its own grant and would break on every rebuild.

```
Rocuronium.app            menu bar item + engine + control socket   ← holds TCC
      ▲ unix socket (~/Library/Application Support/…/control.sock)
      │
   rocuronium CLI         thin client, no TCC, no AX code at all
      │
   MCP server             same verbs, spoken by Claude Code / Rasagiline
```

The CLI launches the app if it isn't running, then speaks JSON over the socket. This mirrors
`RefraxControlServer`, so the pattern is already proven in the suite.

**The socket serializes requests, and the engine depends on it.** A deep AX walk blocks the
`Engine` actor for its full duration (measured 1.2 s on Discord), and `TreeCache` is a plain
class owned by the engine — deliberately not an actor, because the engine already serializes
it. That is safe *only while* the accept loop handles one request at a time. Making the
server concurrent without making walks interruptible would let one slow target stall every
other caller — re-derive this trade before touching either side. (Review 2026-08-02, item B.)

**Menu bar presence doubles as the safety indicator.** The icon is dimmed when idle and
active while the engine is driving, which answers the standing "is it working?" complaint by
construction — the same trick Dantrolene uses for home/away.

**Working on this — three traps that cost real time:**

- **The debug loop is build-sign-install.** The socket verifies the peer's code signature
  (team `52K336H235`) against its audit token, so `.build/debug/rocuronium` is refused —
  correctly. Use `./Scripts/release.sh --install` (notarization ~4 min; run it backgrounded),
  then `/Applications/Rocuronium.app/Contents/Resources/rocuronium`.
- **The CLI lives in `Contents/Resources`, never `Contents/MacOS`** — the filesystem is
  case-insensitive, so `rocuronium` there overwrites the app's own `Rocuronium` executable.
- **`AXUIElement` is not `Sendable`** (checked against the SDK, not assumed). Elements are
  created, used, and discarded inside the `Engine` actor and never cross its boundary; the
  module's default isolation is MainActor, engine types are explicitly `nonisolated`.
- **A second instance steals the socket path.** Binding unlinks whatever file is at
  `control.sock`, so a debug build run from Xcode takes the path from the release daemon,
  and when it quits the daemon is left listening on an unlinked inode: the app runs, the
  file exists, and every connect fails instantly. `Scripts/install-launchagent.sh` quits
  the daemon and re-registers it. A daemon that notices its path was replaced and
  re-binds is on the interface plan.

## 2. Module layout

```
Rocuronium/
  App/          RocuroniumApp, MenuBarIcon, PopoverPages, Theme        ← Dantrolene pattern
  Core/
    Perception/ AXElement, ElementQuery, ScreenCapture, Snapshot
    Actuation/  GhostReach, AXWriter, EventPoster, HIDPoster
    Evidence/   Evidence, Verifier, ScreenDiff
    Environment/DisplayWake, AdrafinilBridge, DantroleneBridge, TrustCheck
    Targets/    AppTarget, ChromiumSupport, WebKitSupport
  Vision/       GroundingBackend, ModelStore, MLXBackend, ScreenshotBackend
  Control/      ControlServer, Commands
  Presence/     PresenceOverlay, ActivityLog
RocuroniumCLI/  thin client
RocuroniumShared/ wire types shared by app + CLI
```

`Core/` must not import `App/` or SwiftUI. The engine has to be testable headlessly and
reusable from the CLI path without dragging the UI in.

## 3. Perception — never single-source

Three sources, fused, because each one lies differently:

| source | cost | fails when |
|---|---|---|
| `kAXFocusedUIElement` | instant | nothing is focused |
| deep AX walk | ~1.2 s for Discord's 5,320 elements | depth-capped, or display asleep |
| screen pixels | ~50 ms | tells you *what*, never *which element* |

**Measured depth rule.** Discord's message box sits at **depth 23** in a 5,320-element tree. A
12-level cap — a reasonable-looking default — makes it invisible and produces the false
conclusion "this Electron app exposes nothing." Default `maxDepth` is therefore **40**, and
any truncation must be reported in the result, never silent.

**Prefer targeted queries to walks.** `AXUIElementCopyElementAtPosition` (hit-test) and the
focused-element query are O(1) and should be tried before any walk. The full walk is the
fallback, not the default.

**Walks are cached between attempts** (`TreeCache`), because the reach may consult the tree
several times while working through its tentacles and 1.2 s each time is the difference between
immediate and broken. The hard part is knowing when the cache became a lie, and a timer alone
does not know. Each entry carries a **fingerprint** — focused-element signature, window count,
front window title, and display-awake state — all O(1) reads, re-taken on every hit; if the
fingerprint moved, the walk is redone. Two details matter: the fingerprint is re-taken *after*
the walk (a walk takes a second, and the UI can move during it), and any display power
transition flushes every process at once, since that changes the shape of every tree
simultaneously.

## 4. Actuation — the ghost reach

Tentacles are attempted in order; each one is verified before falling through. Tentacles 0–3 never
move the cursor or change the frontmost app (measured, every call).

| tentacle | mechanism | verified working on |
|---|---|---|
| 0 | **ensure display awake** | precondition — skip and everything below silently fails |
| 1 | `AXSetValue` / `AXUIElementPerformAction`, read back | AppKit, Electron |
| 2 | `CGEvent.postToPid` with **unicode payload** | AppKit, Electron |
| 3 | app's own automation (`refrax-ctl`, CDP) | WebKit/Chromium page content |
| 4 | real HID `CGEventPost` — **moves the cursor**, opt-in per call | games, hostile event loops |

Two measured constraints are baked in:

- **Electron ignores keycode-only events.** Backspace and Cmd+A posted to Discord did nothing
  while unicode text worked, because Chromium reads the unicode payload. Editing operations
  (clear, select-all) are therefore tentacle-1 operations, never tentacle-2.
- **`AXSetValue` returns `.success` on WebKit while changing nothing.** The return code is not
  evidence. Tentacle 1 is only "successful" after a read-back confirms it.

## 5. Evidence — the feature, not the logging

Every action returns an `Evidence` value, and the verdict is computed, never asserted:

- `.confirmed` — read-back matches, or pixels changed in the target's rectangle
- `.noEffect` — call reported success, nothing observably changed (the WebKit case)
- `.unverifiable` — no readable value and no pixel access; says so instead of claiming success

Verification is tiered so the cheap tier covers most cases: **pixel diff of the target's
rectangle is free and instant** and answers "did the click do anything?" without any model.
A vision model is only needed for "did the *right* thing happen?" — semantic verification.

## 6. Electron support

**Decision: deep AX first, CDP as an opt-in escape hatch.**

The tree is complete and workable — Discord's real fields are all present, just deep, and
`AXSetValue` on the focused element works (it cleared a message box in testing). So Electron
needs no special transport, only correct traversal. `ChromiumSupport` adds:

1. Set `AXManualAccessibility = true` on the app element when first touching a Chromium app.
   Documented Electron behavior for forcing the a11y tree; harmless when it's already on.
   (Measured: accepted, but depth was the real blocker — do not rely on this alone.)
2. Depth budget raised and truncation surfaced.
3. Unicode-only key delivery, per the keycode finding.

**CDP is deliberately not the default.** Attaching requires relaunching the target with
`--remote-debugging-port`, which is a hostile thing to do to a user's running Discord, and
production builds may refuse it. Discord's `127.0.0.1:6463` is its RPC/game-integration
socket, not CDP — not usable for this.

For WebKit (Safari, Refrax) the browser's own channel — `refrax-ctl`, WebDriver, Safari's
scripting — is the only path, since OS-level input cannot reach the separate WebContent
process at all.

**Keyboard shortcuts go through the menu bar, not the keyboard.** `shortcut --keys cmd+a`
locates the menu item carrying the shortcut (`AXMenuItemCmdChar`/`CmdVirtualKey` plus the
Carbon modifier mask, where 0 means plain Cmd) and presses it — no CGEvent, no focus change,
and it works on Chromium, which ignores keycode-only posted events entirely. Measured limits
(2026-08-02 review, item 16 — the review doc is retired; full text in git history): background *AppKit* apps never validate their
menus, so the press returns success and does nothing — accurately foretold by the item's
disabled state, which the reply surfaces. Background *Electron* apps keep items enabled and
the press is best-effort: a parked Postman opened a real tab right after launch, then the
same mechanism silently no-oped minutes later, success codes throughout. The rule:
dependable frontmost, best-effort in the background, and the verdict says which happened.
Verification is selection read-back first, then a window-true pixel diff that may only
confirm, never refute — copy changes no pixels and must not read as failure.

**Tentacle 3 is therefore a referral, not an adapter** (decided 2026-08-02). When the reach is
exhausted on a target inside an `AXWebArea`, `WebContent` identifies the engine — Refrax and
Safari by bundle id, Chromium by id prefix, Electron structurally by its embedded framework —
and the evidence carries a structured `referral` naming the channel that can reach it and the
concrete next move. The calling agent composes that tool itself: it holds the task context and
the launch flags, an adapter here would couple this app to external binaries, and the
automatic fall-through an adapter promises is hollow when CDP needs a flag only a relaunch
can provide. Native controls in browsers (the address bar) never trigger a referral — the
test is `AXWebArea` ancestry, not app identity — and Electron composers that succeed on
tentacle 2 never reach it.

## 7. Local models — storage and role

**Role.** Models exist so the calling agent can be *less* specific ("click the send button"
instead of coordinates) and so reports can be semantic ("the message was sent"). They are an
**enhancement, never a dependency**: with no model installed, targeting falls back to AX plus
hit-testing, and verification falls back to pixel diff.

**Backends** behind one `GroundingBackend` protocol:

| backend | when | cost |
|---|---|---|
| `ScreenshotBackend` | default — hands pixels to the calling agent's own model | free |
| `MLXBackend` | local UI-TARS-1.5-7B / Holo1-7B via MLX | ~4–8 GB, one-time |
| `HeuristicBackend` | pixel diff and AX only | free, no semantics |

**Storage.**

```
~/Library/Application Support/glass.kagerou.rocuronium/
  Models/
    manifest.json               registry: id, revision, sha256, bytes, license
    ui-tars-1.5-7b-4bit/        weights, downloaded lazily, never bundled
  control.sock
  Logs/
```

Rules: models are **never** in the app bundle (a 7 GB `.app` is undistributable and blocks
notarization/homebrew); download is explicit and user-initiated with visible size and license;
integrity is checked by sha256 against the manifest; eviction is a menu action showing disk
use. A model directory is disposable — deleting it degrades to `ScreenshotBackend`, never
breaks the app.

## 8. Suite integration

- **adrafinil** — `AdrafinilBridge` (Dantrolene's pattern: rotated keys, TTL, serialized CLI
  calls, synchronous release on quit) holds a **display-class** hold (`acquire --display`,
  shipped in Adrafinil 2026-08) for the whole agent session: placed on the first
  perceiving/acting command, renewed while commands keep arriving, released after ~4 quiet
  minutes. Adrafinil's daemon owns the policy that outranks it (pause, idle release, thermal
  cutouts). Without the CLI the same lifecycle runs on a process-local IOPM assertion —
  enhancement, never dependency. Tentacle 0's per-action wake stays: it is what wakes an
  already-dark panel. Measured 2026-08-22: `IOPMAssertionDeclareUserActivity` does **not**
  reset `HIDIdleTime`, so neither wake nor hold corrupts presence readings.
- **dantrolene** — owns lock policy; rocuronium defers rather than duplicating. Lock alone is
  harmless to agents; display sleep is not.
- **Test Display.app** — park driven windows on the virtual screen for true isolation.
- **rasagiline** — the cockpit renders presence and the activity log; rocuronium only reports.

## 9. Presence — invisibility is not politeness

Being invisible and being considerate are different properties. An agent working while someone
is typing should behave differently from one working at 4 a.m. against a locked screen — not
because the mechanism differs, but because the cost of being wrong does.

`UserPresence` reads HID idle time, lock state, and display power, and resolves to
`present` / `idle` / `away` / `unknown`. **The default is assume-present**: when presence
cannot be determined, the cautious reading is that someone is here.

This is *propagated to the agent rather than acted on unilaterally*. Every status response
carries the reading plus a machine-readable `mayTakeCursor` (true only when `away`) and a
sentence of advice. The engine still refuses the sting unless the caller opts in — presence
informs the decision, it does not silently make it. The agent is the one with the task context;
it should know that a human just touched the keyboard.

## 10. The virtual display as a lease

The headless virtual screen is the strongest isolation available: windows parked there occupy
none of the pixels a human is looking at. It is also wasteful to leave running and confusing
to find unexpectedly, so it is modeled as a **lease**, not a mode — acquired for a reason,
released when done.

The display is created **in process** by `VirtualDisplayManager`, on the private
`CGVirtualDisplay` ObjC classes (the macOS 26 SDK exports the symbols in CoreGraphics.tbd for
linkage; no public header exists, so a local bridging header declares them). 1920×1080 @2x,
named "Rocuronium Display", origin at `(mainWidth, 0)` so the main display — and with it the
menu bar, notification banners, and system prompts — keeps its zero origin; creation asserts
`CGMainDisplayID()` is unchanged and rolls back otherwise. In process, "the display exists"
and "we own it" are the same fact: attach is the object's nonzero `displayID` (no launch
polling, no name matching), and the display dies with the last lease or the daemon. Creation
failure degrades to "isolation unavailable", never a crash — the private API's shape has
moved across SDK versions.

Two rules keep it from becoming a liability, both learned from Adrafinil's hold design:

- **Ownership.** Our display dies with its leases; a display the user started
  (Test Display.app, `glass.kagerou.testdisplay`) is *adopted* as a parking target and never
  torn down — theirs is left exactly as found.
- **Expiry.** Every lease has a deadline and renews rather than duplicates, so a crashed agent
  cannot strand a virtual screen and concurrent tasks share one display instead of racing.
  And **teardown always un-parks first**: expiry and release sweep every still-parked window
  back to its recorded `before` frame before the display goes (tearing the display out from
  under a window strands it where nobody can see or reach it — measured on a real Finder
  window), and the daemon's startup sweeps any window left on no display back to the main
  screen.

Over the socket this is three verbs. `display acquire|release|status` manages leases.
`park --app` moves an app's primary window onto the virtual screen (or to `--x/--y`, which is
also the undo: the reply carries the window's previous position), with the landing read back
as evidence because the window manager may clamp or refuse. Parking with no lease in force
takes an **auto-lease** — reason recorded from the command, id in the reply, visible in
`display status`, so a stray virtual screen stays traceable to a recorded reason (the
load-bearing guarantee; the two-step ceremony was only ever its carrier). Auto-leases track
the windows they parked and release themselves when the last one is returned or closes;
explicit leases release only by the holder's hand. Attaching a display while a human is at
the keyboard is a visible event, so that step is presence-gated behind `allowDisplayAttach`,
mirroring `allowHardwareInput`. The ledger of parked windows also defines **strays** —
windows on the virtual display nobody parked (a saved frame restored there at launch, a
second window of a parked app): `windows` and `display status` name them, release warns and
sweeps them, and the menu bar badges while any exist. The sting occlusion refusal keeps
*suggesting* park (a machine-readable `suggestion` field) and never auto-parks — moving a
visible window off-screen as a side effect of a failed click is the agent's call, not ours.
`screenshot` is the default vision backend made concrete — capture and hand the pixels to the
calling model. An `--app` capture uses `SCContentFilter(desktopIndependentWindow:)`, never a
region of the display: a region returns whatever is topmost there, and an occluded window
would be captured as someone else's pixels at exactly the right size (measured, 2026-08-02
review item 15). Region and full-display captures keep visible-pixel semantics, which is the
right question for a diff.

## 9b. The visible agent — Presence/

The one direction invisibility must reverse: when the agent takes the cursor, the human
deserves to see it happen and to be able to stop it. `Presence/` is that module — a
borderless overlay window (whisper tint, centered narration bezel, the jellyfish escort,
charge-ring/ripple effects), an `ActivityLog` ring buffer served by the `activity` verb,
and the ⌃⌥⇧⎋ emergency stop.

Two boundaries hold it together. Core never imports Presence: the engine telegraphs
hardware actions through `PresenceRelay`'s static hooks (installed once at launch), and
the halt is `EmergencyStop` — a Core-side atomic checked by every walk, poll loop, and
per-sample in `HardwareInput`, so the fastest stop path is one ~8 ms trace sample and a
mid-payload `type` stops between characters. And resume is asymmetric by design: ⌃⌥⇧⎋ can
be pressed by anyone, but the flag is cleared only by the menu bar popover's button —
no socket verb can un-halt the engine, so an agent cannot talk its way past a human who
took the machine back. The overlay shows for hardware-input opt-ins and the cursor-path
verbs always, for everything else behind a user toggle; ghost tentacles stay invisible by
design, because tentacles 0–3 take nothing from the human that needs announcing.

## 9a. The sting — hardware input

The cursor-stealing tentacle is implemented: `CGEvent`s on `.cghidEventTap`, behaving exactly like
human input. It is reachable only when the caller passes `allowHardwareInput`, and it refuses
outright in two cases — when the screen is locked (the console belongs to the password field
then) and when another app's window covers the aim point.

That second guard is the non-obvious one, and it exists because the sting breaks an assumption
every other tentacle shares: `postToPid` reaches a *process* through any occlusion, but a real
click goes to whatever window is topmost at the coordinate. Measured: fifteen windows
overlapped one point on the main display. So an occluded target is refused with the occluder
named, and parking the target on the virtual display is the reliable way to satisfy the check
— which is what ties this tentacle to the isolation machinery instead of leaving it a hazard.

The pointer is moved to aim and restored afterwards, but `cursorMovedByUs` derives from the
tentacle rather than from the before/after measurement the restore would zero out: the restore is
a courtesy and must never conceal the takeover.

## 10a. The MCP surface

`rocuronium mcp` speaks Model Context Protocol over stdio, exposing the same eight commands as
typed tools so agent harnesses do not have to shell out and parse text. Register it with

```
claude mcp add rocuronium -- /Applications/Rocuronium.app/Contents/Resources/rocuronium mcp
```

It is a hand-written JSON-RPC loop (initialize, ping, tools/list, tools/call) in the CLI, not a
new build product: an SDK dependency would mean a second binary to sign and notarize for
~150 lines of protocol. Each tool call becomes one authenticated socket round-trip and returns
the reply JSON verbatim, so an agent sees exactly the evidence a CLI user sees — including
`verdict`, `cursorMovedByUs`, and any `referral`. The safety semantics live in the tool
descriptions, because that text is what an agent reads when choosing a tool.

## 11. Non-goals

The agent loop (Claude Code owns it), a scripting DSL (the CLI is the DSL), cloud anything,
cross-platform, and Mac App Store distribution — the required entitlements make MAS impossible,
so this ships direct + homebrew cask like Adrafinil.

**Explicitly declined: unlocking the machine.** Disassembly of Codex's shipped implementation
shows `allow_locked_computer_use` is not "keep working while locked" — it is a full auto-unlock
system. A `CUALockScreenGuardian` detects the lock, clicks the reveal prompt through
accessibility, types the user's credentials, and presses Return; it is gated by a SecurityAgent
authorization plugin installed into `/Library/Security/SecurityAgentPlugins/`, and their
installer runs as root to **rewrite the `system.login.screensaver` right in the system
authorization database**.

Rocuronium will not do any of this: no credential entry, no SecurityAgent plugin, no
modification of the authorization database, no root installer. The capability it would buy is
one we already have without it — we measured that a locked session with an awake display
exposes full accessibility trees, so the engine already works through a lock. What auto-unlock
adds is the ability to defeat the lock a human deliberately engaged, and a lock that software
can talk its way past is not a lock. If unattended work needs the screen unlocked, that is the
user's decision to make in advance, not ours to make on their behalf at 4 a.m.
