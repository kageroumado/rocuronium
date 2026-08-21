# Roadmap — the path off Peekaboo

*The prioritized work list for making rocuronium the only Mac-control tool this household
needs. Decided with Kiri 2026-08-04 after the "what's actually useful" discussion.*

**KEEP THIS CURRENT.** At the end of every work session that touches an item here: mark it
done with the date and commit hash, note anything measured that changed the plan, and
re-order what remains if the work taught something. A stale roadmap is worse than none —
the next session trusts this file over its own guesses. The companion memory
(`project_rocuronium.md` in the memory hub) points here; it should stay a pointer, with
state living in this file.

**House rules that bind all of it** (details in ARCHITECTURE §1): the debug loop is
build-sign-install (`./Scripts/release.sh --install`, notarization ~4 min backgrounded,
then `/Applications/Rocuronium.app/Contents/Resources/rocuronium`); every behavior change
is verified on the installed build by *running* it — the worst bugs of 2026-08-02 (SIGPIPE
DoS, emoji crash) were found by execution, not by three reviewers reading the diff; a
return code is never evidence; new delivery mechanisms re-derive every assumption
(review item 17's lesson).

---

## Phase 1 — Verb parity — **DONE 2026-08-04** (04f6c6f), loose ends below

All six items shipped and were verified by running the installed build; the per-item
specs moved to the Done section. What the session measured, and what it left open:

- **Walks needed to be interruptible in *serial* operation, not just for a future
  concurrent server.** Finder (desktop window full of icons) exceeded the socket's 30 s
  inside the 60k element budget, and an abandoned walk kept the engine busy so every
  queued request starved behind it — two Finder walks poisoned the socket for a minute.
  Walks now observe `Task.isCancelled` and an 18 s wall-clock deadline and report
  truncation. Finder remains the pathological target: a full-tree label query gives 18 s
  of truncated walk, and which window the walk enters first is not deterministic.
- **Posted scroll-wheel events do not exist as a ghost mechanism** (experiment log §6):
  ignored in pixel and line units by AppKit and Chromium alike. `scroll`'s primary
  mechanism is therefore `AXScrollToVisible` on a labeled element (verified working on
  Chromium, frame read-back as evidence); scroll-bar value writes (`--to`) work only
  where a bar is exposed (rare — overlay scrollers hide it; Chromium never has one), and
  bare `--dy` posts wheels that will honestly report `noEffect`.

### Phase-1 loose ends (small, ordered)

1. ~~`find`/`named()` matches labels only~~ — **DONE 2026-08-09.** `named()` matches
   labels first and element *values* as the fallback tier, in one walk — a value match
   never competes with a label match, which keeps the noise out. Verified on Mail: a
   subject string that existed only as a static-text value (label was the role
   description "text") resolved through the fallback.
2. ~~`--to` scroll bars by role walk~~ — **DONE 2026-08-09.** `Engine.verticalScrollBar(of:)`
   tries the attribute, then a bounded two-level child walk for `AXScrollBar` with a
   numeric value, preferring taller-than-wide. Verified on TextEdit (attribute absent,
   overlay scroller): write read back 0.615 → 0.900. **The open measurement is answered:
   the value write moves the actual content, not just the bar** — a 119-line document
   screenshotted at `--to 0` showed lines 1–27 and at `--to 1` lines 92–119.
3. ~~`activate` success path~~ — **VERIFIED 2026-08-09 04:29** (unlocked away run,
   temporary 60 s gate, reverted after): `activate` without confirm landed on TextEdit
   and Safari — `frontmost` read back as the target, `focusTakenByUs: true`. Both
   regimes now measured: unlocked-away activates; locked-away is refused by the system
   (`loginwindow` keeps the console — first run, 03:08).
   Findings the two runs left behind:
   - Background delivery diverges per app *and lies in both directions*: TextEdit's
     background File ▸ New + typed text looked dead but **actually landed** (the text
     surfaced in the document an hour later); Safari honored background ⌘L and
     navigated the user's real front tab. Treat every unverifiable background press as
     "may have happened", not "didn't".
   - Rung-0 display wake works behind the lock; display-asleep away windows never
     satisfied an "unlocked + idle" trigger until the script held the display awake
     (`caffeinate -d`) — kept as the experiment pattern.
4. `AXScrollToVisible` off-screen path still unmeasured: on the loaded Wikipedia page
   "External links" matched **no element** even though `read` returned the full page
   untruncated — the section heading simply is not in the AX tree (likely below the
   rendered viewport). Needs a target whose off-screen content materializes in AX.
5. ~~WebKit scroll + read behavior~~ — **MEASURED 2026-08-09 04:30** on frontmost
   Safari: `read` returns real page text (14,808 chars, untruncated, no referral
   needed — the silent-web-area case did not occur); **Safari exposes a writable
   vertical scroll bar** and `--to` round-tripped 0 → 1 → 0 confirmed; bare posted
   wheels are ignored (honest noEffect + the safari-js referral). WebKit is therefore
   the *best*-behaved web toolkit for `scroll --to`, not the worst.
6. **`key` reaches focused text controls but not sheet key-equivalents** (measured
   2026-08-09 04:29, frontmost): `key return` into Safari's focused address field
   committed navigation (confirmed; page loaded in 1.3 s) — but `key escape` did not
   cancel a frontmost TextEdit save sheet (posted per-pid, sheet persisted, honest
   unverifiable). Escape/cancel routes through key-equivalent dispatch that per-pid
   posted events evidently do not reach. Agent guidance (now in the guide): press the
   sheet's button by label (`click --label Cancel --role button` — verified working)
   instead of Escape. Possible future rung: a session-level key post while the target
   is frontmost, gated like hardware input since it hits global focus.
   More of the same, measured 2026-08-22: an *open menu* is unreachable by every ghost
   mechanism — posted Escape to the host **and** to the menu-owning appex both no-op
   (menu tracking runs its own event loop), and re-pressing the menu button does not
   toggle. Once a menu is open the ghost options are "choose an item" or "quit the
   host"; in the guide.
7. ~~An action whose consequence is a window or element appearing/vanishing reads as
   failure~~ — **DONE 2026-08-20.** `Evidence.confirmedByWindowCountChange` is the
   read-back for the window-list family: `press` (menu/shortcut), `act` (click), and
   `pressKey` now take the target's on-screen window count before acting and, when the
   verdict is not confirmed, poll it briefly after (6×200 ms; 3 for `key`, whose caret
   presses legitimately stay unverifiable). In `press` the poll is merged with the
   process-exit loop and exit wins — "the app quit" is the message that stops a
   dangerous retry, and a dead app's count would read "→ 0" anyway. Original measured
   cases (2026-08-09, away run): Cancel dismissing its own sheet read `noEffect`;
   File ▸ New read `unverifiable` while opening a window; a close button read
   `unverified` — all invisible to element-rect, selection, and same-window pixels.
8. ~~Two instances of the same bundle id refused with no way through~~ — **DONE
   2026-08-22.** `--pid` on every app-taking verb (CLI, socket, and MCP — the `tool()`
   helper adds it uniformly wherever `app` exists); it overrides `app` outright and a
   dead pid is refused. Verified by execution: `read --pid <TextEdit>` dumped the
   document, pid 99999 refused — and it was immediately useful in anger, delivering an
   Escape to a System Settings *appex* pid that has no app name at all.
9. ~~Label queries match menu items~~ — **DONE 2026-08-20.** Exclusion, not demotion:
   demoting menu matches below label matches would not have fixed the measured case
   (`wait --label References` matched the History-menu entry precisely because no
   window match existed yet). `ElementQuery.search` no longer seeds the menu bar and
   skips `AXMenuBar` children in the `AXChildren` seed (the bar arrives through both).
   `menu`/`shortcut` are untouched — MenuQuery has its own resolution — and `read`
   without a label already rooted at the window. Verified by execution: TextEdit
   `find --label Undo` matched `AXMenuItem 'Undo' @(0,1440)` before (the meaningless
   closed-menu frame) and reports "no matches" after, while
   `menu --resolve-only --path "Edit > Undo"` still resolves.
10. ~~`AXMainWindow` can answer with the application element~~ — **fixed 2026-08-09**:
   behind the lock screen Safari's `AXMainWindow` attribute returned the app element
   itself, so `read` dumped 30k characters of menu bar and history instead of the page.
   `Engine.primaryWindow(of:)` now accepts only window-roled elements and falls back to
   `AXWindows` (which answered correctly in the same state); `read`, `windowFrame`,
   `moveWindow`, and scroll-area resolution all go through it.

## Phase 2 — Operator docs + the actual switch — **2.1–2.3 DONE 2026-08-04**

- **2.1** README.md written (135 lines: evidence vocabulary, presence gates, refusal
  catalog, park-then-hardware, display-asleep vs locked, background-app honesty).
  `Scripts/embed-guide.sh` bakes it into the CLI as `Guide.generated.swift` (committed;
  regenerated by release.sh), and `rocuronium guide` prints it from the bare binary.
- **2.2** MCP server registered at user scope in `~/.claude.json`; `claude mcp list`
  reports it connected. Peekaboo's MCP stays registered during the trial.
- **2.3** All four Peekaboo pointers now say "rocuronium first; Peekaboo for what it
  can't do yet": the `reference_peekaboo_control` memory, the peekaboo skill
  description + intro, ATLAS layers 1–2 (+ its stale ghost-mode hole), and the global
  CLAUDE.md computer-control section (which was the strongest steering text and wasn't
  on the original list of three).

### 2.4 Trial week — running since 2026-08-04

Real tasks, rocuronium-only, Peekaboo installed as fallback. Every fallback moment gets
a line in the trial log below — those lines are the Phase-1 gaps that were missed.

**Trial log** *(append: date · task · what rocuronium couldn't do · which tool did it)*

- 2026-08-06 · dismiss a native file-picker dialog in Refrax · no way to send a bare key (Escape) — `type` is text-only, `shortcut` only resolves menu-bar items · `mcp__peekaboo__hotkey` escape
- 2026-08-09 · target the debug Refrax while release Refrax also ran · `find` with app:"Refrax" silently picked one of the two same-named apps (no ambiguity warning) · bundle-ID targeting worked — but a warning or error on ambiguous names would prevent driving the wrong app
- 2026-08-09 · click Refrax's sidebar "Restart to update" button · `click` by label matched 2 elements (AXButton + AXMenuItem share the label) and accepts no role filter — only app/label/x/y — so "be more specific" left coordinates as the sole option · coordinate click (which then failed, next line)
- 2026-08-09 · same task · coordinate ghost click resolved to an AXGroup ("element exposes no press action") and the posted event was noEffect — SwiftUI button, app not frontmost · `menu` path instead
- 2026-08-09 · same task · `menu` flagged "Refrax ▸ Restart to Update — v99.0…" as "would reboot the Mac" — the Restart heuristic fires on app-menu items, not just Apple ▸ · confirm:true (correctly overridable, but the hazard label was wrong)
- 2026-08-09 · same task · the confirmed menu press returned ok:false / verdict "unverifiable" even though the action fully succeeded (app quit, updated, relaunched) — a press that closes the app can never verify, and reporting it as an error invites a dangerous retry
- 2026-08-20 · reproduce a user's physical fullscreen-button click in Refrax (web content) while the window was inactive and partially covered by Warp · rocuronium daemon unreachable (control socket dead — `rocuronium status` fails; likely not running since a reboot/lock) — and this task is its core promise: app-targeted ghost clicks immune to z-order, no cursor steal · Peekaboo foreground CGEvent clicks, which repeatedly landed on the covering Warp window at the same global coords until Refrax was floated with keep-on-top; each misfire silently activated the wrong app. Two asks: (1) launchd/keepalive so the daemon survives reboots — **DONE 2026-08-20**, see Done; (2) a `click` that targets web-content elements inside a WKWebView by AX label even when the app is inactive/covered (Peekaboo could only do it after raising the window) — **answered same day, next line**: the ghost AX press did exactly this once the daemon was back up.
- 2026-08-20 · locate YouTube's fullscreen button in Refrax web content · `find --app Refrax "Full screen"` returned two unrelated search fields (AXComboBox 'Search', AXTextField) and never the AXButton 'Full screen (f)' — while `click --label "Full screen"` on the same tree correctly matched it (ambiguous with the traffic-light 'full screen button'); find and click disagree on matching semantics, and find's fuzzy results didn't include the exact-substring hit · `read | rg` to discover the true label, then `click --label "Full screen (f)"` — which worked perfectly (ghost AX press on an inactive, covered window; the whole reason for the task). Same-day win worth noting: that click is something Peekaboo could only do after raising the window.
- 2026-08-10 · verify Sevoflurane's Steam supernav hover flow (open on hover, keep-open while gliding into the flyout, dismiss on mouse-away) · no way to *move* a cursor at all — hover states, hover-intent timers, and enter/leave chains are untestable without real pointer motion, so every iteration burned a human test pass · Kiri's hands, repeatedly. **Feature ask (Kiri, 2026-08-10): simulated cursor paths — move from point to point along a straight line or a curve (Bézier, like vector editors draw), at a controllable speed, optionally with left/right button held, so hover/drag/glide flows can be driven and verified without touching the real cursor.** Note the ghost-rung tension: hover requires the system cursor position to actually change (tracking areas follow the real pointer), so this likely lives on the hardware rung, presence-gated like other cursor-taking verbs — or drives per-app synthetic mouse-moved event streams (CGEvent posts with per-event positions, cursor unmoved) where the target app's tracking allows it. **RESOLVED 2026-08-20** — the tension was measured (ghost motion does not exist on macOS) and the verbs shipped on the hardware rung: see Done.

- 2026-08-20 · press an "Add Video" AXMenuButton inside System Settings' Wallpaper pane (an AXOpaqueProviderGroup hosting remote elements from the pane appex) · `find` sees the element fine, but `click` reports "element exposes no press action" and the posted-event fallback is noEffect — menu buttons need the AXShowMenu action, which no rung attempts; posted events also appear to go to the host System Settings pid while hit-testing lives in the appex process · nothing did it cursor-free — a hand-rolled trusted AX walker couldn't even reach the element (opaque provider group children aren't in AXChildren for a plain walker, and walking the appex pid directly yields a bare app element), so rocuronium's traversal is the only tool that can see these elements and just lacks an AXShowMenu/press verb on them — **ADDRESSED 2026-08-22**: the press rung performs `AXShowMenu` when no `AXPress` exists (`AXElement.pressishAction`), and the click on the Wallpaper pane's opaque-provider menu button verifiably opened its menu (region screenshot). Two residues, both in the guide: the menu window belongs to the *appex*, so the window-count read-back on the targeted app misses it and the verdict honestly stays `unverifiable`; and an open menu has no ghost dismissal (see loose end 6's 2026-08-22 addendum)
- 2026-08-22 · open a MenuBarExtra popover (Phosphene status item) to drive its controls · `find role:AXMenuBarItem` returns no matches for the app (status items live in a separate extras menu bar the walker never reaches), so there is no ghost press for a status item at all · `mcp__peekaboo__click` at menu-bar coordinates — which steals the cursor, exactly what presence-gating forbids. Gap: enumerate + AXPress NSStatusItems, pid-scoped so two instances sharing a bundle id stay distinguishable. — **ADDRESSED same day**: new `statusitem` verb reads the app element's `AXExtrasMenuBar` (list, or `--press` by AXPress with the window count as read-back, since the press call itself can block in menu tracking). Verified on the original Phosphene case: popover opened (windows 1 → 2, confirmed) and toggled closed (2 → 1), cursor untouched.
- 2026-08-20 · same task, hardware fallback · `click` with allowHardwareInput:true stayed on the posted-event rung (presence: user present/idle, mayTakeCursor false) — correct gating, noted here only to record that the hardware rung was the sole remaining path and etiquette blocked it · deferred to the human at the keyboard

**All six trial-log gaps addressed 2026-08-09 (c89eefa)** (verified by execution on the
installed build; the trial continues — new fallback moments still get lines above):

- *Bare keys* → new `key` verb: named keys (escape, return, tab, arrows, home/end,
  page up/down, delete) with optional modifiers, posted per-pid, menu-press-style window
  pixel evidence. Delivery to *background* AppKit dialogs measured no-effect — honest
  verdict, and loose end 6 tracks the frontmost-case verification.
- *Ambiguous app names* → `resolve` refuses when several running apps share the name,
  listing name/bundle/pid for each; bundle ids are matched exactly and win. Verified
  with two TextEdit instances (`open -n`).
- *No role filter* → `--role` on find/read/wait/type/click/scroll ("button" or
  "AXButton"); `find --role button` with no label lists a role. Verified on Notes:
  "New Note" refused as 2 elements, resolved with `--role button`.
- *Coordinate click hits an AXGroup* → click-shaped actions ascend from the hit-test
  element to the nearest pressable ancestor (bounded, stops at windows). Verified on
  Calculator: a raw-coordinate click resolved and pressed `AXButton '1'`.
- *Restart heuristic too broad* → session-wide hazard patterns (log out, shut down,
  restart, sleep, lock screen) now require the path to start at **Apple ▸**;
  data-destroying patterns stay global. Verified three ways: Apple ▸ Restart… still
  refuses, Simulator's Device ▸ Restart no longer does, Finder's File ▸ Move to Trash
  still does.
- *Press that closes the app reads as error* → when a menu/shortcut press's verdict is
  not confirmed, the engine polls ~1.2 s for the target process exiting; an exit is the
  read-back (`confirmed`, "the target process exited after the press"). Verified:
  cmd+q on background TextEdit came back ok:true confirmed.

Also found and fixed while verifying: `click`'s evidence only diffed the *element's*
rectangle, so a press whose consequence lands elsewhere in the window read as a false
`noEffect` (Calculator: display changed, button rect quiet). Click-shaped actions now
take the same window-true two-capture evidence as menu presses. Measured calibration
consequence: a real consequence can be small at window scale (the display change was
0.27%, under the 2% confirmed threshold), so on a provably-still window a mid-band
delta softens an element-rect `noEffect` to `unverifiable` — conflicting evidence never
leaves a refutation standing. Getting such clicks all the way to `confirmed` needs a
semantic channel, which is phase 4's vision tier.

## Phase 3 — Display hold — **DONE 2026-08-22** (adrafinil side shipped 2026-08)

Adrafinil shipped display-class holds (`hold --display`, `acquire --display`,
`keep_display_awake` on MCP); rocuronium's side is `AdrafinilBridge`: a session-level
display hold placed on the first perceiving/acting command, renewed with rotated keys
while commands keep arriving, released after ~4 quiet minutes, swept synchronously on
quit. Falls back to a process-local IOPM assertion when the CLI is missing **or the
daemon is down** (measured on this machine: installed CLI, dead daemon, soft-failing
acquire — the bridge switches to `internal` rather than believing exit 0). `status`
reports `displayHold: adrafinil | internal | none`.

**Measurement 1 answered 2026-08-22**: `IOPMAssertionDeclareUserActivity` does **not**
reset `HIDIdleTime` (19.33 s before → 19.64 s at +0.3 s → 21.65 s at +2.3 s, kept
counting). `ensureAwake` never had the presence-integrity exposure; neither does the
hold.

## Phase 4 — Vision tiers (the AX-dead 18%; ~1 week)

**First slice shipped 2026-08-22**: `TextSighting` (Vision fast OCR, no model download)
powering `scroll --until-text` — capture the window, OCR locally (~100 ms/frame), stop
the moment the string is legible; the reply carries the sighting's screen rectangle for
a coordinate click. Verified: needle at line 150 of a 200-line TextEdit doc sighted in
7 bar-steps / 3.7 s, honest scanned-to-the-end on an absent needle. This is the OCR
half of the detector tier; the YOLO half and the VLM tier remain below.

Research: `~/Developer/Research/gui-grounding-models-2026-08.md` (harness in
`gui-grounding-2026-08/`). The January model table in ARCHITECTURE §7 is invalidated —
Holo1-7B is research-licensed, UI-TARS is superseded. Order:

1. **Head-to-head** (~1 day): convert `mPLUG/GUI-Owl-1.5-4B-Instruct` to MLX 4-bit, run
   against `pipenetwork/Holo-3.1-4B-MLX-4bit` on 50–100 annotated macOS screenshots. This
   resolves the only open question (published macOS numbers vs turnkey weights).
2. **Rewrite ARCHITECTURE §7** with the winner and the three-tier design: AX →
   YOLO-on-ANE + Vision OCR (~20 ms) → VLM (~3 s, rare).
3. **`MLXBackend`** via `mlx-swift-lm` (pin main, not 3.31.4). Two traps that must be
   explicit code, not config trust: cap image input to ~1.0 MP (the shipping
   preprocessor config admits a raw 5K screenshot un-downscaled → 108 s/call), and the
   coordinate convention is a **per-model manifest property** (Qwen3.5-era = normalized
   0–1000, Qwen2.5-era = absolute pixels; getting it backwards makes a working model
   look broken).
4. **Detector tier** (YOLO on ANE + Vision OCR union). `.cpuAndNeuralEngine` only —
   `.cpuAndGPU` hard-crashes on macOS 26.5. Tiling strategy is the real design decision.
5. **Semantic verification** via Foundation Models `Attachment`, behind a macOS 27
   availability check — covers "was the message sent?" with zero download.

## Standing constraints (not work — read before touching adjacent code)

- The socket serializes requests and `Engine`/`TreeCache` depend on it (ARCHITECTURE §1).
  Going concurrent requires interruptible walks first.
- `AXUIElement` never leaves the `Engine` actor.
- The CLI lives in `Contents/Resources`, never `Contents/MacOS`.

## Done

- **2026-08-22 — release-readiness batch: status items, AXShowMenu, `--pid`, the display
  hold, and OCR scrolling.** Five gaps closed in one pass, all verified by execution on
  the installed build:
  - `statusitem` (extras menu bar; the 2026-08-22 trial gap) — Phosphene popover opened
    and closed, window count as read-back both ways.
  - `AXShowMenu` as a press (the 2026-08-20 trial gap) — the Wallpaper pane's
    opaque-provider menu button visibly opened its menu; appex-owned menu windows and
    the no-ghost-dismissal residue documented in the guide.
  - `--pid` targeting everywhere (loose end 8) — including MCP, added uniformly by the
    `tool()` helper.
  - `AdrafinilBridge` display-class session hold (Phase 3's rocuronium side) with
    rotated keys, quit sweep, and a fallback to a process-local assertion measured
    against a dead daemon; measurement 1 answered (no `HIDIdleTime` reset).
  - `scroll --until-text` on Vision fast OCR (`TextSighting`, Phase 4's first slice) —
    needle at line 150 sighted in 7 steps/3.7 s, honest end-of-document on a miss,
    `foundAt` rectangle ready for a coordinate click.

- **2026-08-20 · 506e187 — cursor paths: `move` and `drag` (the 2026-08-10 trial-log ask).**
  Measurement first (`~/Developer/Experiments/cursor-paths/RESULTS.md`): per-pid posted
  motion is dropped wholesale by the window server — tracking areas, SwiftUI `onHover`,
  WebKit hover, content drags and title-bar drags all silent, background *and* frontmost,
  with and without window-number stamping — so **there is no ghost rung for motion**, and
  the verbs live on the hardware rung, presence-gated like `activate` (refused unless
  away or `--confirm`; refused while locked; occlusion at the action point refused when
  `--app` is given). `PathPlan` (Catmull-Rom through `--via` waypoints, arc-length
  parameterized, easing, ~120 Hz samples; unit-tested) + `HardwareInput.trace` (double-
  precision delta stamping — integer per-event rounding measured +33% drift over 40
  steps; mid-path lock/cancel abort that releases a held button where it stopped) +
  router verbs with cursor-position read-back and target window-count before/after as
  flyout evidence. Measured along the way, now in the guide: HID motion lands on the
  topmost window at the point (Refrax's PIP panel silently ate a hover); WebKit drops
  all motion for inactive windows while AppKit `.activeAlways` tracking fires in the
  background; `acceptsFirstMouse` swallows background content drags; title-bar drags
  move background windows without activating. The same harness ran the real-cursor
  verification Sevoflurane's supernav fix chain was waiting on (open → keep-open glide →
  Steam's own 200 ms dismiss, zero clicks — `sevoflurane/HANDOFF.md` updated).

- **2026-08-20 · 1240544 — launchd keepalive + stale-bundle cleanup.** The daemon is a LaunchAgent
  (`~/Library/LaunchAgents/glass.kagerou.rocuronium.plist`: RunAtLoad, KeepAlive
  SuccessfulExit=false — crash/kill respawns, menu-bar Quit stays quit), installed by
  `Scripts/install-launchagent.sh`, which `release.sh --install` now runs instead of
  `open`. Verified: `kill -9` → new pid serving the socket in <4 s, Accessibility grant
  intact. Two rot sources found and fixed while here: `ditto` *merges* into an existing
  bundle, so the installed app carried Aug-2 debug dylibs and failed strict codesign
  (install now trashes the old bundle first); and the "dead Hello-world window with a
  Dock icon" was a stale lowercase `rocuronium.app` template scaffold in DerivedData
  sharing the real bundle id, which `open` resolved by name — trashed. Old
  `pkill -f Rocuronium.app` also matched every CLI/MCP client by path; now `pkill -x`.

- **2026-08-04 · 04f6c6f — Phase 1, verb parity.** `read` (bounded text dump; silent
  `AXWebArea` reported as hidden-not-blank with a read referral), `apps`/`windows`
  (window rows carry display + virtual-display + on-no-display), `menu` (path press
  through the same machinery as `shortcut`; refusals list the level's real items),
  `wait` (25 s cap, `callAgain`), `launch` (activates:false + drivability poll, 0.9 s
  cold Calculator), `activate` (presence-gated, read-back verdict), `scroll`
  (`AXScrollToVisible` primary after measurement killed posted wheels — log §6).
  Interruptible walks: `Task.isCancelled` + 18 s deadline in every tree walk, after two
  abandoned Finder walks starved the socket for a minute. Verified by execution on the
  installed build: Finder, Notes, Mail, Discord, Calculator. Loose ends listed in the
  Phase 1 section.
