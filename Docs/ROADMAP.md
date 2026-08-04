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

## Phase 1 — Verb parity (unblocks everything; ~2–3 days)

The act-side is complete; the observe/navigate side is thin. Priority within the phase is
usage frequency, measured against what actually gets done in a Peekaboo session today.

### 1.1 `read` — text out of an app without pixels

The most-used verb the tool doesn't have. Dump the AX text of an element (by `--label`) or
a whole window: static text, field values, button titles, checked states. ~1000× cheaper
in tokens than screenshot+vision and works while the screen is locked.

- Bound the output (element count + character cap) the way `MenuQuery` bounds its walk —
  per-child, not per-entry (item 31's lesson).
- Same `DisplayWake` guard as every perception path: display asleep ⇒ "I cannot see", not
  an empty result.
- WebKit lies (returns success while exposing nothing): when the walk lands in an
  `AXWebArea` with no text, say so and refer to the rung-3 referral, mirroring
  `WebContent.swift`.

### 1.2 `apps` / `windows` — what is running, what windows exist

`NSWorkspace.runningApplications` (regular activation policy) for apps;
per-app AX window list (title, frame, minimized, on which display) for windows. Read-only,
no presence implications. Kills the `lsappinfo`-in-bash prelude every session does now.

### 1.3 `menu` — press an arbitrary menu item by path

`menu --app X --path "File ▸ Export…"` (accept `>` and `▸`). `MenuQuery` already walks
the tree; this adds path matching next to shortcut matching. Hazard rails, `confirm`, and
`resolveOnly` carry over verbatim. Reaches everything that has no shortcut; measured
limits from review item 16 apply (dependable frontmost, best-effort background —
the verdict already says which).

### 1.4 `scroll` — reach off-screen content

Ladder-shaped like everything else: try `AXScrollBar`/`AXScrollArea` value writes first
(read position back — the write returning success is nothing), fall through to posted
`scrollWheel` events to the pid. **Measure before building**: whether Electron/WebKit
honor posted scroll events at all is unknown — same measurement discipline as the
ghost-input experiments, results recorded in the experiment log before the design is
fixed. Evidence: scroll position delta when a scrollbar exposes one, pixel diff otherwise.

### 1.5 `wait` — a polling primitive

`wait --app X --label Y [--gone] [--timeout N]`. Blocks until the element appears (or
disappears), polling the cached tree. **Constraint that shapes it**: the control socket
cancels requests at 30 s (review item 23), so `--timeout` caps at 25 s and the reply says
"timed out, call again" — the caller loops, the socket stays responsive.

### 1.6 `launch` / `activate` — app lifecycle

`launch`: `NSWorkspace.openApplication`, then poll until the AX tree answers (launch
without readiness is a lie — the reply must mean "you can drive it now"). `activate`
raises an app and **takes focus, so it is presence-gated**: refused while a human is
present unless `confirm: true`, same shape as the other rails. Needed because background
delivery is best-effort on Electron (item 16) — sometimes bringing the app forward is the
honest option, and it should be a named, gated verb rather than a side effect.

## Phase 2 — Operator docs + the actual switch (~1 day)

### 2.1 README.md + `rocuronium guide`

The MCP tool descriptions already teach *acting*; nothing teaches *interpreting*. A
~150-line operator README at the repo root covering: the evidence vocabulary
(`confirmed` / `noEffect` / `unverifiable` — and that `unverifiable` means don't retry
blindly), the presence block and what gates on it, the refusal catalog (`submit`,
`confirm`, `allowHardwareInput`, lease — each named with when it's legitimate), the
park-then-hardware pattern, display-asleep vs screen-locked. Single source: README.md,
embedded into the CLI at build time so `rocuronium guide` prints it — an agent with just
the binary self-serves, and no skill ever needs to exist.

### 2.2 Register the MCP server at user scope

`claude mcp add rocuronium -- /Applications/Rocuronium.app/Contents/Resources/rocuronium mcp`
(user scope). Peekaboo's MCP stays registered during the trial.

### 2.3 Update the three places that say "use Peekaboo"

The `reference_peekaboo_control` memory, the peekaboo skill's trigger text, and ATLAS
layers 1–2. Each gets "rocuronium first; Peekaboo for what it can't do yet" until the
trial ends, then the full handover.

### 2.4 Trial week

Real tasks, rocuronium-only, Peekaboo installed as fallback. Every fallback moment gets a
line in this file — those lines are the Phase-1 gaps that were missed.

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

*(move items here with date + commit as they land)*
