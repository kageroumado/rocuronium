# Locked-screen control & local models — research memo

*For rocuronium (`~/Developer/rocuronium`). Written 2026-08-22 by a research subagent with
live web access. Read-only pass over the repo; nothing in `~/Developer/rocuronium` was
touched. Sources at the bottom of each part.*

---

# PART 1 — Locked-screen agent control, current landscape

## The line rocuronium holds (recap, so the matrix is judged against it)

From `ARCHITECTURE.md §11` and `README.md`: rocuronium **already works through a lock** in
the only sense it cares about — a *locked-but-awake* session exposes full AX trees and ghost
rungs 0–3 deliver (AX writes, unicode `CGEvent.postToPid`). What it refuses:

- **Hardware input (rung 4) while locked** — synthetic keystrokes would land in loginwindow's
  password field; occlusion/lock guards refuse it.
- **`activate` while locked** — loginwindow owns the console; cooperative activation can't
  promote an app behind the lock.
- **Anything that defeats the lock a human engaged**: no credential entry, no SecurityAgent
  plugin, no `system.login.screensaver` authorization-DB rewrite, no root installer. That is
  the explicit non-goal, aimed squarely at Codex's `allow_locked_computer_use`.

The research question is therefore narrow: **is there a sanctioned way to run *hardware-grade*
UI work (cursor, real clicks, frontmost activation) while the local console stays locked,
without crossing that line?** The short answer: not on the local console, but **yes in a
*separate* GUI session** via Screen Sharing's virtual display — that is the one genuinely
promising direction.

## (a) OpenAI Codex — Locked Use shipped and is now official

Rocuronium's disassembly was of a pre-release build; the feature is now **publicly shipped and
documented** (announced **2026-05-21**). Confirmed details, matching the disassembly:

- It **installs an Apple authorization plug-in that participates in the macOS unlock flow** —
  i.e. the SecurityAgent-plugin + auth-right mechanism rocuronium found, now stated openly.
- OpenAI frames it as **auto-unlock, deliberately narrow**: "not a general-purpose
  remote-unlock path… doesn't let other apps or local processes unlock the computer."
- Runtime guardrails they now document: unlock is gated to a **"trusted turn"**, **displays
  are covered (blanked) while the desktop is temporarily unlocked**, and it **relocks on any
  local keyboard/pointer input**.
- Carve-outs: **unavailable in EEA / UK / Switzerland**; cannot automate Terminal, Codex
  itself, or system admin prompts.

Security commentary (Macworld, heise, MacRumors) is uneasy but not alarmed — the framing is
"an AI can now unlock your Mac," and the mitigations above are what makes it shippable. **This
does not change rocuronium's decision**: the capability is still "defeat the lock," still
requires the auth-DB-adjacent plugin, and rocuronium's stance ("a lock software can talk past
is not a lock") reads *stronger* now that the mechanism is public, not weaker. Nothing to
copy; one thing to note — Codex's "**cover the displays while unlocked**" is the same
blanking primitive that Screen Sharing gives for free (below).

## (b) Other computer-use products at the lock boundary

- **Anthropic Claude Computer Use** (macOS desktop, shipped **2026-03-23**, ~2 months before
  Codex): **halts at the lock.** The agent stops when the display turns off; there is **no
  Anthropic-side unlock**. Same posture as rocuronium — work while awake, stop at the lock.
- **Google Project Mariner / Jarvis**: **browser-scoped** (Chrome extension). No OS-level
  lock story at all; not a macOS-session actor. Irrelevant to the locked-console problem
  except as evidence that the serious desktop players split into exactly two camps: *halt at
  lock* (Anthropic, rocuronium) or *auto-unlock* (Codex). Nobody else has found a third door
  on the **local console**.

The third door exists only by **leaving the local console alone and working in another
session** — which is Screen Sharing.

## (c) Legitimate mechanisms in a locked session — the capability matrix

Legend for **source**: `measured` = rocuronium's own on-device tests (RESULTS.md / README);
`documented` = Apple or vendor docs; `reported` = credible secondary reporting; `unverified`
= plausible, not tested here.

### Same-session, local console locked (display awake)

| Mechanism | Behavior while locked | Source |
|---|---|---|
| AX read / deep walk (`AXUIElementCopy*`) | **Works** — full trees readable | measured |
| `AXSetValue` / `AXUIElementPerformAction` (rung 1) | **Works** (AppKit, Electron) | measured |
| `CGEvent.postToPid` unicode (rung 2) | **Works** (AppKit, Electron) | measured |
| App-own automation (rung 3: refrax-ctl/CDP) | Works (channel-dependent) | measured |
| ScreenCaptureKit / screenshot | Works while **display awake**; collapses if display sleeps | measured |
| Display **asleep** (any of the above) | **Blind** — every AX tree collapses to the app element; `caffeinate -u` to wake (`-d` won't) | measured |
| Session event tap / `CGEventPost` to `.cghidEventTap` (rung 4) | **Refused/ineffective** — console owned by loginwindow; keystrokes hit the password field | measured |
| `activate` / cooperative raise | **Refused** — loginwindow owns frontmost | measured |
| Real cursor move/drag | **Refused** — presence-gated + lock guard | measured |

Net: **rocuronium's rungs 0–3 are the ceiling of what the local locked console legitimately
allows.** There is no sanctioned local mechanism for hardware-grade input behind the lock that
isn't "unlock it." This is a hard wall, correctly identified.

### Different-session mechanisms (the way around the wall)

| Mechanism | Behavior | Source |
|---|---|---|
| **Screen Sharing, High Performance mode, virtual display** | HP mode drives a **virtual display that bypasses the physical displays**; you can request **1 or 2** virtual displays. Connecting in HP mode **locks the local (physical) console**, and the physical displays are **blanked** when you authenticate as the logged-in user. | documented |
| **Screen Sharing concurrent login (different user)** | If a session already exists, macOS offers "**log in concurrently using a different username and screen**" — you get the Mac "**but won't share the same screen**." A full separate GUI login session with its own display. | documented |
| Headless-Mac auto virtual display | A Mac with **no display attached** auto-creates a **private virtual display** for the remote session. | documented |
| loginwindow / pre-login capture | **Restricted** on Sequoia+: pre-login context can't be screen-captured by ordinary daemons; loginwindow lives in a restricted Mach bootstrap namespace. RDP-class apps bridge it with a **Global LaunchAgent `LimitLoadToSessionType=["LoginWindow"]`** running as root + **`com.apple.developer.persistent-content-capture`** (a *managed* entitlement Apple grants by application, undocumented otherwise). | reported |
| Curtain Mode (ARD / Remote Management) | Freezes the host screen; **requires Remote Management**, does **not** work with plain Screen Sharing. | documented |

## (d) Viable directions that preserve the "no credential entry, no auth-DB" line

The line rocuronium drew is specifically **"don't defeat the lock a human engaged on the local
console."** A remote GUI login the *user themselves* initiates through Apple's sanctioned
Screen Sharing protocol is a different act — it is the user logging in, not software forging an
unlock. Three directions, best first:

1. **Run the agent inside a Screen-Sharing High-Performance virtual-display session
   (recommended to prototype).** The user (or an automation the user set up) opens a Screen
   Sharing / HP connection to the Mac; HP mode spins up a **virtual display**, blanks the
   physical screens, and locks the local console. Inside *that* session the desktop is a live,
   unlocked GUI — so **rung 4 hardware input, `activate`, and cursor motion all become
   legitimate**, because they act on a virtual display no human is looking at, in a session the
   user authenticated. This is the sanctioned analogue of Codex's "cover the displays while
   working," except macOS provides the covering and the unlock is the user's own remote login,
   not a plugin rewriting the auth DB. **Nothing rocuronium refuses is crossed.** It also
   composes perfectly with the existing **virtual-display lease** machinery (`§10`): the
   HP-shared display is just another parked surface.
   - *Open questions to measure* (none blocking, all cheap): does a `park`-style window move
     land on the HP virtual display; can the daemon (a LaunchAgent) reach that session's
     WindowServer; does HP mode require a *second* user account or can it re-attach the
     locked user's own session to a virtual display. The concurrent-different-user path
     sidesteps the last question entirely — a dedicated "agent" login account.

2. **Headless / virtual-display-only operation as first-class, not a lease afterthought.**
   The `virtual-display-research` teammate is already on adjacent ground. The
   headless-Mac-auto-virtual-display fact means an **agent account with no physical display**
   gets a private GUI session for free. Kiri's always-on Mac Studio is the ideal host: a
   second "agent" account, logged in and left at a virtual display, is a permanent
   hardware-input-legal workspace that never touches the console she's using.

3. **Explicitly decline the loginwindow/persistent-content-capture route** — document it the
   way §11 documents Codex. It needs a root LaunchAgent in the LoginWindow session type and a
   **managed entitlement Apple hand-grants** (and which breaks App Store submission). It buys
   pre-*login* operation, which is strictly more than "work while locked" and lands on the
   wrong side of rocuronium's line for the same reasons the Codex plugin does. Worth a
   one-paragraph non-goal so it doesn't get re-proposed.

**Bottom line for Part 1:** the local locked console is a solved, closed question — rungs 0–3
are the legitimate ceiling and rocuronium already hits it. The unsolved, *promising* frontier
is **Screen Sharing's High-Performance virtual display**, which turns "hardware input is
illegal while locked" into "hardware input is legal in a session nobody is looking at,"
without any of the auth-DB machinery rocuronium refuses. That is the direction worth a
measurement spike, and it dovetails with the display-lease design already in the tree.

### Part 1 sources
- Codex Locked Use: Macworld `macworld.com/article/3147024`, heise `heise.de/en/news/OpenAI-Codex-controls-Mac-even-in-locked-state-11306153.html`, MacRumors `macrumors.com/2026/05/22/codex-use-mac-apps-when-locked/`, aifeaturedrop.com 2026-05 explainer.
- Claude Computer Use lock behavior: thenewstack.io/claude-computer-use/, productivetechtalk.com 2026-03-26.
- Project Mariner/Jarvis scope: em360tech.com, itpro.com.
- Screen Sharing HP / virtual display / concurrent login / blanking: Apple Support `support.apple.com/guide/remote-desktop/apdf8e09f5a9`, `support.apple.com/.../mchl1883115d` (screen sharing type options), Six Colors 2026-06 HP-mode post, 9to5mac.com 2026-02-05, Apple Community thread 255609419.
- Pre-login/loginwindow + persistent-content-capture: Apple Developer forums thread 768146 & 814152, mjtsai.com 2024-08-08.

---

# PART 2 — Local models for cheap next-action + screen understanding

## The August research still stands — landscape did **not** materially move

`~/Developer/Research/gui-grounding-models-2026-08.md` (2026-08-03) remains current. A web
sweep for anything newer (July–Aug 2026 GUI-grounding releases, MLX conversions, Apple UI
understanding) surfaced **only the same generation** the memo already ranks:

- **GUI-Owl-1.5 / UI-Venus-1.5 / EvoCUA** are confirmed as "the next generation of specialist
  GUI agents in 2026, all fine-tuned from Qwen3-VL." **UI-Venus-1.5 tops the ScreenSpot-Pro
  official leaderboard among open-source end-to-end grounding-only models** — consistent with
  the memo (UI-Venus-1.5-8B at 68.4, the accuracy ceiling you can actually run). EvoCUA is new
  as a *name* here but is same-cohort, no MLX weights, no reason to displace the 4B pick.
- **GUI-Owl-1.5-4B-Instruct still has no MLX 4-bit conversion** (HF shows only the old-gen
  `mlx-community/GUI-Owl-7B-4bit` and the bf16 `mPLUG/GUI-Owl-1.5-8B`). So the head-to-head
  **still requires a self-conversion**, exactly as the memo said. No shortcut appeared.
- **Apple, WWDC26 / macOS 27 Foundation Models**: confirmed **vision via image attachments**
  (UIImage/NSImage/CGImage/CIImage/CVPixelBuffer/URL, any size), plus callable **`OCRTool`**
  and **`BarcodeReaderTool`**. This *re-confirms the memo's finding*: Apple gives you
  **semantic verification and OCR, never coordinates/bounding boxes.** It covers "was the
  message sent?" for free at ~3B behind a macOS 27 check; it does **not** ground. No Apple
  UI-element detector shipped. The private `UIUnderstanding.framework` remains
  entitlement-gated and unusable.

**Conclusion: keep the memo's recommendation.** Ship **Holo-3.1-4B** (Apache-2.0, turnkey MLX
4-bit `pipenetwork/Holo-3.1-4B-MLX-4bit`, measured 3.0 s/call 3/3) as the default grounder,
with **GUI-Owl-1.5-4B (MIT, macOS 88.4% published)** as the challenger the head-to-head exists
to settle.

## (1) Harness readiness — what exists, what's missing, effort

**Exists** (`~/Developer/Research/gui-grounding-2026-08/`):
- `eval2.py` — a working single-model grounding runner: loads an MLX-VLM repo, caps input to
  `max_pixels=1003520`, resizes to a 28-multiple, prompts the Qwen "Click(x,y)" grounding
  template, parses the first `(x,y)`, rescales **resized-frame → full-res**, and scores
  HIT/miss against hand-eyeballed boxes. **N=3 targets, one screenshot (`shot2.png`,
  5120×2880).** This is a *smoke test*, self-described as such.
- `bench.swift` / `bench2.swift` — the CoreML/ANE detector-timing harness (YOLO on
  `.cpuAndNeuralEngine`).
- `shot2.png` — the one test image.

**Missing to run the real head-to-head:**
1. **The GUI-Owl-1.5-4B MLX weights.** One `mlx_vlm.convert` job, **~15 min**, ~2.9 GB out.
   (`Holo-3.1-4B` weights are turnkey — no conversion.)
2. **A real annotated set.** `eval2.py`'s 3 eyeballed boxes cannot rank two models within
   ±10 points. Need **50–100 real macOS screenshots with hand-annotated boxes** — this is the
   actual labor. Budget **2–4 h** to capture + annotate (a mix: AX-rich AppKit, Electron,
   WebKit content, icon-only toolbars — bias toward the AX-dead 18% that justifies the model
   at all). A tiny labeling helper (click two corners, dump JSON) is ~30 min to write.
3. **Per-model coordinate-convention handling in the scorer.** `eval2.py` currently rescales
   as if coords are **absolute pixels in the resized frame** (Qwen2.5-VL convention). For
   **Holo-3.1-4B (`qwen3_5`) the model emits normalized 0–1000** — feeding it through the
   pixel path is exactly the "0/3 that was really 3/3" landmine the memo flags. The harness
   needs a **per-model `coord_convention` flag** (`pixels_resized` vs `normalized_1000`)
   before it can score both fairly. **~30 min.**
4. **Metrics beyond HIT/miss**: per-call latency + prefill (already printed), plus
   center-distance and per-category accuracy (text vs icon vs webarea). **~1 h.**

**Total effort to a trustworthy head-to-head: ~1 day**, dominated by annotation, exactly as
the ROADMAP estimates. Nothing is architecturally blocked; the pieces are one conversion, one
labeled set, and two scorer fixes.

## (2) Action-prediction vs pure grounding — which candidates do what

The lead's key idea: **a local cheap model decides "what's the next action" in a scripted
multi-step sequence**, so not every screenshot round-trips to the big model. This needs a
distinction the memo doesn't draw explicitly:

- **Grounding** = *instruction + screenshot → coordinates* ("click the send button" → (x,y)).
  All the candidates do this; it's what ScreenSpot-Pro measures.
- **Action-prediction / planning** = *goal + screenshot (+ history) → next structured action*
  (`click(send)` vs `type("hi")` vs `scroll` vs `done`). This is a **strictly harder,
  different output** — it decides *what verb* and *whether the step is finished*, not just
  where.

Where the candidates land:
- **GUI-Owl-1.5 / UI-Venus-1.5 / Holo-3.1** are trained as **native agents** (the Mobile-Agent-v3
  / UI-TARS lineage), so they emit **action space output, not just points** — GUI-Owl's own
  paper reports MMBench-GUI **L2 (grounding)** *and* higher-level agentic scores. So yes, the
  4B tier *can* do lightweight action-prediction, not only grounding. **But** at 3 s/call an
  agent that plans *every* step locally is slow, and small models plan worse than they ground.

**The right division of labor is the one the lead sketched, and it's correct:**

> **Big model plans once** (decomposes the goal into an ordered, concrete step list, each with
> an expected postcondition) **→ local 4B grounds each step + verifies each step's
> postcondition** → only escalate back to the big model on a verdict mismatch or an
> off-script surprise.

This uses each tier for what it's good at. The local model is asked the *easy* question
("where is the Send button", "did a composer window appear") — grounding + verification, which
4B does at ~66–88% and which rocuronium can **cross-check for free** with its existing
evidence engine (AX read-back, pixel diff, window-count delta). It is **not** asked the hard
open-ended "what should I do now," which stays with the planner. The local model's
action-prediction ability is the *fallback* for "the script diverged, pick the recovery step,"
not the main loop.

Crucially, **rocuronium already owns the verification half**: `§5` evidence verdicts
(`confirmed`/`noEffect`/`unverifiable`) via read-back and pixel diff. So "verify each step's
expected postcondition" is *largely a non-model operation* — the local VLM is only needed for
**semantic** postconditions ("the text now reads 'Sent'"), which macOS 27 Foundation Models
covers for free. The cheap-tier stack becomes: **AX/pixel evidence (free) → YOLO+OCR ground
(~20 ms) → Holo-3.1-4B ground/verify (~3 s, rare) → big model replan (only on mismatch).**

## (3) Token/latency economics — rough real units

Baseline to beat — **every step to the big model** (the pattern this replaces): a screenshot
is a large image payload. A 5K macOS screenshot downscaled to ~1 MP is on the order of
**~1–1.5 k image tokens** to a Claude-class model per step, plus prompt/history, plus network
round-trip latency of **~1–3 s/step** and real per-image cost. A 10-step task = **10 uploads,
~10–20 k image tokens, ~15–30 s** of just model+network.

The tiered pattern:
- **Plan once**: 1 big-model call with 1 screenshot (~1.5 k image tokens) + goal → step list.
- **Per step, local**: grounding is **~1 k image tokens *inside MLX*, zero API tokens, ~3 s
  on M1 Max** (memo-measured; **~1.2–1.5 s extrapolated on the Studio's M-Ultra**). Most
  steps also resolve at the **~20 ms YOLO+OCR tier** or the **free AX/pixel tier** and never
  invoke the VLM at all.
- **Escalate rarely**: big-model replan only on a verdict mismatch — say 1–2 of 10 steps.

So a 10-step task goes from **~10 big-model image calls → ~2–3** (1 plan + 1–2 replans). That
is a **~70–80% cut in big-model image tokens and API round-trips**, trading them for local
compute that is free-but-not-instant (~3 s worst case, ~20 ms typical). **The economics favor
the split whenever a task is more than a couple of steps and network/API cost dominates local
latency** — which is the normal case. The one regime where it *loses* is a 1–2 step task,
where planning overhead isn't amortized; there, just call the big model.

Caveat carried from the memo: these are **M1 Max smoke-test numbers (N=3)**, and the ANE
detector timings are real but the VLM latency is 3 targets on one image. The head-to-head is
what turns these into a defensible curve.

## (4) The concrete first experiment to run

**Goal:** settle Holo-3.1-4B vs GUI-Owl-1.5-4B on real macOS screenshots, and produce the
per-model coordinate-convention + latency numbers `MLXBackend` needs. **~1 day, annotation
dominates.**

```bash
cd ~/Developer/Research/gui-grounding-2026-08

# 1. Convert the challenger to MLX 4-bit (~15 min, ~2.9 GB). Holo-3.1-4B needs no conversion.
python -m mlx_vlm.convert --hf-path mPLUG/GUI-Owl-1.5-4B-Instruct \
  --mlx-path ./gui-owl-1.5-4b-4bit -q --q-bits 4

# 2. Capture 50-100 real macOS screenshots (bias toward AX-dead: WebKit content, Electron,
#    icon-only toolbars) and hand-annotate boxes -> targets.json. This is the real work (~2-4 h).
#    A 2-corner-click labeler is ~30 min to write.

# 3. Generalize eval2.py: read targets.json, add a per-model coord_convention flag
#    (Holo-3.1-4B = normalized_1000 ; GUI-Owl-1.5-4B (qwen3_vl) = pixels_resized),
#    add center-distance + per-category accuracy. (~1.5 h)

# 4. Run both, same set, temperature 0, image capped to 1_003_520 px.
python eval2.py 4b        # pipenetwork/Holo-3.1-4B-MLX-4bit (turnkey)
python eval2.py gui-owl   # ./gui-owl-1.5-4b-4bit (add this branch)
```

**Decision rule:** if GUI-Owl-1.5-4B matches or beats Holo-3.1-4B on the AX-dead subset at
comparable latency, ship it (MIT > Apache-2.0, and it has the published macOS 88.4% number);
otherwise ship Holo-3.1-4B (turnkey weights, one fewer conversion to maintain). **Set the
pixel cap and the per-model coordinate convention explicitly** — those two lines are the whole
difference between a working grounder and one that looks broken (memo §5).

Then, and only then: `MLXBackend` via `mlx-swift-lm` (pin `main`), the YOLO-on-ANE + Vision-OCR
detector tier (`.cpuAndNeuralEngine` only — `.cpuAndGPU` hard-crashes on macOS 26.5), and
Foundation Models `Attachment` semantic verification behind a macOS 27 availability check.

### Part 2 sources
- `~/Developer/Research/gui-grounding-models-2026-08.md` (primary, still current) + harness `~/Developer/Research/gui-grounding-2026-08/`.
- Model cohort: arxiv.org/pdf/2508.15144 (Mobile-Agent-v3 / GUI-Owl), ScreenSpot-Pro leaderboard `github.com/likaixin2000/screenspot-pro-gui-grounding`, huggingface.co/mPLUG & mlx-community listings (GUI-Owl-1.5-4B MLX absent).
- Apple FM macOS 27 vision: developer.apple.com/videos/play/wwdc2026/241, apple.com/newsroom/2026/06 intelligence frameworks.
