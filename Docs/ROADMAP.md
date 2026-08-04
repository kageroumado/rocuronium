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

1. `find`/`named()` matches **labels only**, but the text an agent sees in `read` output
   is often a *value* (note bodies, static text). A label that exists only as a value is
   unfindable and un-scrollable-to. Decide: extend `named()` to values (noisy?) or add a
   `--value` match flag.
2. `--to` could find scroll bars by **role walk** when the `AXVerticalScrollBar`
   attribute is absent. Measured 2026-08-04 in Notes: the note body's text area has a
   sibling `AXScrollBar` element (numeric value exposed, read 0.000) while the enclosing
   scroll area answers nothing for the `AXVerticalScrollBar` *attribute* — so
   `scroll --to` refuses on a view that in fact has a writable bar. Overlay scrollers
   (the default since 10.7) are the suspected reason the attribute is absent, which
   makes this the common case on modern AppKit, not a Notes quirk (Mail's scroll area
   also had no attribute). Implementation shape: in `Engine.scroll`'s `toFraction`
   path, when `area.verticalScrollBar` is nil, walk the area's children (bounded, one
   level or two) for `role == "AXScrollBar"` with a numeric value and prefer the one
   whose frame is taller than wide — horizontal bars have the same role. Write and
   read back exactly as now; the verdict machinery needs no change. Re-measure whether
   the write actually moves overlay-scroller content or just the bar: the read-back
   plus window-true pixel diff already distinguishes those two outcomes.
3. `activate --confirm` success path deliberately unverified: presence read `present`
   (idle 0 s) all session, and stealing focus from a present human to test the
   anti-focus-stealing tool was declined. Verify in the next away window.
4. `AXScrollToVisible` moved-frame path verified on Chromium only via the
   already-visible branch; exercise a genuinely off-screen target (needs a target whose
   off-screen rows materialize in AX — Notes' list virtualizes them away).
5. WebKit (Safari/Refrax) scroll + read-referral behavior unmeasured — Safari was not
   running and opening windows on a present user's screen was declined.

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

- *(no fallbacks yet)*

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
