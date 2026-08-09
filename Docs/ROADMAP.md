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
3. `activate --confirm` success path deliberately unverified: presence read `present`
   (idle 0 s) all session (again 2026-08-09), and stealing focus from a present human to
   test the anti-focus-stealing tool was declined. Verify in the next away window.
4. `AXScrollToVisible` moved-frame path verified on Chromium only via the
   already-visible branch; exercise a genuinely off-screen target (needs a target whose
   off-screen rows materialize in AX — Notes' list virtualizes them away).
5. WebKit (Safari/Refrax) scroll + read-referral behavior unmeasured — Safari was not
   running and opening windows on a present user's screen was declined.
6. **`key` delivery to background AppKit dialogs measured no-effect** (2026-08-09): a
   posted Escape did not dismiss a background TextEdit save sheet — pixelDelta 0, sheet
   still present, honestly reported `unverifiable`. A background app has no key window
   to route key events to, the same class of limit as background menu validation. The
   verb's real case (the frontmost app an agent is driving, or after `activate`) needs
   an away-window verification.
7. **An element that vanishes because the press worked reads as failure** (2026-08-09):
   ghost-pressing a save sheet's Cancel dismissed the sheet, but the verdict was
   `noEffect` — focus never changed and the pressed button no longer existed to testify.
   The element-level sibling of the process-exit evidence: "target provably gone after a
   dismissal-shaped press" is evidence of success. Not implemented yet because Electron
   rebuilds elements on focus (a dead handle there is routine, and refetch-fails is not
   proof of disappearance) — needs a design that doesn't false-confirm on Electron.
8. Two instances of the **same bundle id** (`open -n`) are refused as ambiguous — right
   call, but the refusal's advice (target by bundle id) has nothing to offer there. If
   this happens in practice, a `--pid` locator is the answer; wait for a real occurrence.

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

## Phase 3 — Display hold (overnight capability; ~3 days, mostly in adrafinil)

Full spec: `~/Developer/adrafinil/Docs/DISPLAY-HOLD-SPEC.md` (committed 344b15f). Five
must-verify measurements before shipping, the first being whether
`IOPMAssertionDeclareUserActivity` resets `HIDIdleTime` — rocuronium's own `ensureAwake`
has that presence-integrity exposure *today*, so measurement 1 is worth running even
before the adrafinil work starts.

## Phase 4 — Vision tiers (the AX-dead 18%; ~1 week)

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
