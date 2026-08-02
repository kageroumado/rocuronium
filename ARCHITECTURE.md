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

**Menu bar presence doubles as the safety indicator.** The icon is dimmed when idle and
active while the engine is driving, which answers the standing "is it working?" complaint by
construction — the same trick Dantrolene uses for home/away.

## 2. Module layout

```
Rocuronium/
  App/          RocuroniumApp, MenuBarIcon, PopoverPages, Theme        ← Dantrolene pattern
  Core/
    Perception/ AXElement, ElementQuery, ScreenCapture, Snapshot
    Actuation/  GhostLadder, AXWriter, EventPoster, HIDPoster
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

**Walks are cached between attempts** (`TreeCache`), because the ladder may consult the tree
several times while working through its rungs and 1.2 s each time is the difference between
immediate and broken. The hard part is knowing when the cache became a lie, and a timer alone
does not know. Each entry carries a **fingerprint** — focused-element signature, window count,
front window title, and display-awake state — all O(1) reads, re-taken on every hit; if the
fingerprint moved, the walk is redone. Two details matter: the fingerprint is re-taken *after*
the walk (a walk takes a second, and the UI can move during it), and any display power
transition flushes every process at once, since that changes the shape of every tree
simultaneously.

## 4. Actuation — the ghost ladder

Rungs are attempted in order; each one is verified before falling through. Rungs 0–3 never
move the cursor or change the frontmost app (measured, every call).

| rung | mechanism | verified working on |
|---|---|---|
| 0 | **ensure display awake** | precondition — skip and everything below silently fails |
| 1 | `AXSetValue` / `AXUIElementPerformAction`, read back | AppKit, Electron |
| 2 | `CGEvent.postToPid` with **unicode payload** | AppKit, Electron |
| 3 | app's own automation (`refrax-ctl`, CDP) | WebKit/Chromium page content |
| 4 | real HID `CGEventPost` — **moves the cursor**, opt-in per call | games, hostile event loops |

Two measured constraints are baked in:

- **Electron ignores keycode-only events.** Backspace and Cmd+A posted to Discord did nothing
  while unicode text worked, because Chromium reads the unicode payload. Editing operations
  (clear, select-all) are therefore rung-1 operations, never rung-2.
- **`AXSetValue` returns `.success` on WebKit while changing nothing.** The return code is not
  evidence. Rung 1 is only "successful" after a read-back confirms it.

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
production builds may refuse it. Where the app *is* launched by us, CDP gives exact DOM
control and becomes rung 3. Discord's `127.0.0.1:6463` is its RPC/game-integration socket, not
CDP — not usable for this.

For WebKit (Safari, Refrax) rung 3 means `refrax-ctl` and WebDriver, since OS-level input
cannot reach the separate WebContent process at all.

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

- **adrafinil** — reuse Dantrolene's `AdrafinilBridge` pattern verbatim (refcounted keys, TTL,
  key rotation, App Store compile-out). **Requires a new display-class hold**: Adrafinil today
  keeps the *system* awake while letting the *display* sleep, which is exactly the state that
  collapses every AX tree. Until that ships, `DisplayWake` falls back to
  `IOPMAssertionDeclareUserActivity`.
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
sentence of advice. The engine still refuses rung 4 unless the caller opts in — presence
informs the decision, it does not silently make it. The agent is the one with the task context;
it should know that a human just touched the keyboard.

## 10. The virtual display as a lease

The headless virtual screen (`Test Display.app`) is the strongest isolation available: windows
parked there occupy none of the pixels a human is looking at. It is also wasteful to leave
running and confusing to find unexpectedly, so it is modeled as a **lease**, not a mode —
acquired for a reason, released when done.

Two rules keep it from becoming a liability, both learned from Adrafinil's hold design:

- **Ownership.** The display is torn down only if this app started it. One the user started is
  theirs, and is left exactly as found.
- **Expiry.** Every lease has a deadline and renews rather than duplicates, so a crashed agent
  cannot strand a virtual screen and concurrent tasks share one display instead of racing.

Test Display exposes no URL scheme or CLI, so the bridge launches and terminates the bundle
(`glass.kagerou.testdisplay`) with `activates = false`, then waits for the screen to actually
register — launching is not attaching.

## 11. Non-goals

The agent loop (Claude Code owns it), a scripting DSL (the CLI is the DSL), cloud anything,
cross-platform, and Mac App Store distribution — the required entitlements make MAS impossible,
so this ships direct + homebrew cask like Adrafinil.
