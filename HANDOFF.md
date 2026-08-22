# Handoff — visible-agent overlay (the last unbuilt spec module)

*Written 2026-08-22 at the end of the release-readiness session. Start here, read the
ROADMAP after, then build. Everything below was decided with Kiri in-session; the design
questions are settled — this is implementation, not exploration.*

## Active Task

Implement the `Presence/` module — the one piece of ARCHITECTURE §2 that has never been
built (DESIGN.md milestone 2: "overlay while driving"): the visible-agent overlay,
emergency stop, activity log, jellyfish menu bar glyph, and the Icon Composer app icon.

## Approved design (Kiri's picks — do not re-litigate)

- **Whisper tint**: ~5% dim (slight desaturation ok) over the desktop while an agent
  session is active in visible mode — the from-across-the-room cue. Almost transparent;
  never hides the work.
- **Centered bezel HUD** (bottom-center, volume-bezel lineage — *not* a corner pill):
  translucent material, jellyfish mark, narration in evidence-verdict language
  ("Evidence: window 'New Message' appeared"), elapsed session time, ⌥⎋ stop chip.
  Rests at ~62% opacity, wakes to 100% for each action.
- **Jellyfish mascot** (Ely's metaphor, Kiri loves it): translucent bell, bioluminescent
  violet→cyan→pink, cute eyes, lagging wave tentacles. States: dim drift idle / cyan glow
  thinking / bell-pulse-toward-target acting / amber curled-tentacles needs-human.
  Escorts the real cursor (spring-follow beside it, never on it); tentacle wake.
- **Default choreography speed** from the prototype (eased glides, charge-up ring before
  each click as the visible interrupt window, ripple on click).
- **Rejected**: edge glow ("cheap"), top banner ("boring"), corner HUD (not idiomatic),
  full tint as-is, the ghost and sigil mascots, **and the "You have control" full-overlay
  takeover flash — on ⌥⎋ just stop and quietly remove the chrome, no ceremony.**

**Reference prototypes** (committed e519501, open in a browser):
`Prototypes/overlay/jellyfish-mascot.html` and `Prototypes/overlay/combined-demo-v2.html`.
Refinements the prototype agent flagged, still valid: the 17 px menu-bar glyph borders on
mushroom (narrower bell, longer tentacle strokes); the bezel's rest/wake opacity step
wants a slower decay, possibly a recede-to-mini-pill tier after ~10 s idle.

## Architecture plan (from a full read of the relevant sources)

New files under `Rocuronium/Presence/` (synchronized groups — files are auto-added):

1. **`OverlayModel.swift`** — `@MainActor @Observable`: phase (hidden / idle / thinking /
   acting / needsHuman), narration text, session start date, pending effects
   (chargeRing(point), ripple(point)), "show for all actions" toggle (UserDefaults-backed).
2. **`PresenceOverlayController.swift`** — owns one borderless NSWindow on the main
   screen (v1): `isOpaque = false`, clear background, `ignoresMouseEvents = true`,
   `level` above normal windows (≈ `.screenSaver`), `collectionBehavior`
   `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`. Hosts the SwiftUI content;
   fade in/out via `alphaValue` animation (tint fades in over ~1 s).
3. **`OverlayViews.swift`** — SwiftUI: TintView (5% dim), BezelView (ultraThinMaterial
   rounded rect, bottom-center), EffectsView (TimelineView/Canvas: charge rings +
   ripples), JellyfishView. **The jellyfish follows the real cursor by polling
   `NSEvent.mouseLocation` per frame in the overlay — zero engine coupling.** Port the
   creature's shapes from the prototype (bell ellipse + gradient, 5 wavy tentacle paths).
4. **`HotkeyMonitor.swift`** — Carbon `RegisterEventHotKey`, ⌥⎋ (`kVK_Escape` = 53,
   `optionKey`), registered only while the overlay is visible; fires the halt on MainActor.

New files under `Rocuronium/Core/` (Core must not import Presence/App — hence the relay):

5. **`Core/Environment/EmergencyStop.swift`** — `nonisolated` atomic halt flag + reason.
   Checked in: `ElementQuery`/`TextDump` walk guards (next to their `Task.isCancelled`
   checks), `Engine` poll loops and `scrollUntilText`'s loop, and
   `HardwareInput.consoleIsStillOurs` (HardwareInput.swift:205) — that one line makes
   `trace` abort mid-sample **releasing any held button** (machinery already exists,
   lines 162–175) and `type` stop mid-character. Fastest stop path ≈ one 8 ms sample.
6. **`Core/Environment/PresenceRelay.swift`** — `nonisolated(unsafe)` static closure
   hooks, set once at app launch (dependency inversion so Core never imports UI):
   - `telegraph(point) async` — draws the charge ring and delays ~600 ms when the overlay
     is visible; returns immediately otherwise. Call before `HardwareInput.click(at: aim)`
     in GhostLadder's rung-4 paths (GhostLadder.swift ~line 210 and ~264) and before
     `HardwareInput.trace` in `Engine.trace` (at `actionPoint`).
   - `impact(point)` — ripple after the click lands.

Wiring in existing files:

7. **`CommandRouter`** — owns `PresenceOverlayController` + `ActivityLog`.
   - Overlay policy: show when `request.allowHardwareInput == true`, when the verb is
     `move`/`drag`, or when the "show for all actions" toggle is on. `begin(action:)` at
     command start, `finish(verdict:)` from the evidenceReply path; the session lingers
     ~15 s after the last command, then fades out.
   - **Halt semantics**: at `execute()` entry, if halted → refuse every acting/perceiving
     verb with "halted by the human (⌥⎋) — resume from the Rocuronium menu bar"
     (`status`/`diag` still answer; `status` gains `"halted": true`). **Resume is a
     menu-bar-popover button only** — human-only by design; no socket verb can clear it.
8. **`ActivityLog.swift`** (Presence/) — MainActor ring buffer (~200 entries: date,
   action, target, verdict, summary), appended wherever evidence is produced. New
   `activity` socket verb (+ CLI case + MCP tool) returning recent entries; popover shows
   the last few; the bezel narration reads from the same entries.
9. **Menu bar glyph** — replace the `cursorarrow` SF Symbols in `RocuroniumApp.swift:14`
   with a programmatic template `NSImage` jellyfish (narrow bell + 4 tentacle strokes;
   idle = stroked/dim, driving = filled — template stays monochrome, so state is
   fill/weight, not color). Keep `isDriving` switching exactly as today.
10. **App icon** — `Rocuronium/Rocuronium.icon/` in the new Icon Composer format:
    `icon.json` + `Assets/*.svg` (1024×1024 viewBox). **Copy the schema from
    `/Users/kirie/Developer/adrafinil/Adrafinil/Adrafinil.icon/`** — display-p3 background
    fill gradient, groups of layers with glass / shadow / specular / translucency.
    Deep-water navy gradient background; layers bottom→top: radial glow, tentacles, bell
    (`"glass": true`), highlight. Then change `ASSETCATALOG_COMPILER_APPICON_NAME` from
    `AppIcon` → `Rocuronium` in **both** configurations of
    `Rocuronium.xcodeproj/project.pbxproj` (currently lines ~338 and ~370).

## House rules that bind this work

- Debug loop is build-sign-install: `./Scripts/release.sh --install` (backgrounded,
  notarization ~4 min), then drive `/Applications/Rocuronium.app/Contents/Resources/rocuronium`.
  **Verify every behavior by running it on the installed build. Return codes are not evidence.**
- The CLI lives in `Contents/Resources`, never `Contents/MacOS` (case-insensitive FS trap).
- `AXUIElement` never leaves the `Engine` actor; Core never imports App/SwiftUI.
- The socket serializes requests — a mid-`move` screenshot must come from
  `/usr/sbin/screencapture` or a backgrounded shell, not a second CLI call.
- Update `README.md` (the guide — embed-guide.sh regenerates the embedded copy during
  release) with the overlay + ⌥⎋ + `activity` sections, and stamp the ROADMAP Done entry
  with date + commit hash when verified.

## Verification plan (all on the installed build)

1. Overlay: run `rocuronium move --to <x,y> --confirm --duration 3`; capture mid-glide
   with `screencapture -x` from a backgrounded shell; confirm tint + bezel + jellyfish
   escort + charge ring are visible in the capture.
2. ⌥⎋: post the chord as real hardware input (`CGEventPost` on the HID tap, keycode 53
   with option held) during a long `move` — confirm the trace aborts mid-path (button
   released, `aborted` in the reply), `status` reports `halted: true`, and acting verbs
   refuse with the resume message.
3. Resume from the popover; confirm verbs work again.
4. `activity` returns the session's entries; popover shows them.
5. Icon: build product shows the jellyfish in Finder/Dock; menu bar glyph reads as a
   jellyfish at 17 px (not a mushroom) in both idle and driving states.

## State of the repo (already done — do not redo)

- `4ffb5ff` — release-readiness batch, all verified by execution: `statusitem` verb,
  `AXShowMenu` presses, `--pid` everywhere, `AdrafinilBridge` display-class session hold
  (falls back to internal when the adrafinil daemon is down — it *is* down on this
  machine), `scroll --until-text` (local Vision OCR, `TextSighting`).
- `1f46e6a` — v1 prototypes + two research memos (`Docs/VIRTUAL-DISPLAY-NOTES.md`,
  `Docs/LOCKED-AND-LOCAL-NOTES.md`).
- `e519501` — v2 prototypes (jellyfish mascot + rebuilt composite).
- ROADMAP is current through `1d57d44`; Phase 3 done; Phase 4 first slice (OCR) shipped;
  Phase 5 candidates listed and awaiting picks — **the overlay (this handoff) is the one
  Kiri picked.**
- The session's three background research agents were stopped by Kiri — all their
  deliverables are already committed; expect nothing further from them.

## Not in scope here (tracked in ROADMAP Phase 4/5)

The vision head-to-head (~1 day, annotation-dominated), absorbing `CGVirtualDisplay`
into the daemon (spike first — measurement list in `Docs/VIRTUAL-DISPLAY-NOTES.md`), and
the Screen Sharing High-Performance locked-session spike.

## Continuation instructions

Read `ARCHITECTURE.md` §2/§9 and skim the two prototype HTML files first (they are the
visual spec). Build in this order: EmergencyStop + relay (small, unblocks everything) →
overlay window + views → router wiring + halt + activity → glyph → icon → release.sh →
the verification plan above → README/ROADMAP updates → commit with the Done entry.
