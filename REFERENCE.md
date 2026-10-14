# rocuronium reference

[Overview](README.md)

## What makes it different

**A dedicated agent session.** Create a second macOS user and run the agent in
its own desktop session, with its own cursor and frontmost app. CLI and MCP
commands can target that desktop while you keep using yours. The session ends
if the owning daemon stops responding, and the emergency stop halts it.

**Ghost input.** Most actions are delivered through accessibility and per-process posted
events — no cursor movement, no focus change, invisible to the person at the keyboard.
The agent works *beside* you, not *instead of* you.

**Evidence, not return codes.** Every action is verified: text is read back after writing,
pixels are compared before and after, window counts are checked, process exits are
detected. The reply says `confirmed`, `noEffect`, or `unverifiable` — and `noEffect`
(the API said "success" but nothing changed) is the most important one.

**The human is never locked out.** Cursor-taking actions show a presence overlay — a
jellyfish escorting the cursor, a bezel narrating what's happening. Touch the mouse and
the gesture yields. Press Ctrl+Option+Shift+Escape and everything stops within one
sample (~8 ms). Resume is a button in the menu bar and nothing else — the agent cannot
un-halt itself.

**A virtual display for isolation.** Park a window onto an invisible headless display,
work on it there with full hardware input (no occlusion, no screen real estate), put it
back. The display exists only while a lease holds it and sweeps every window home on
teardown.

**Sequence plans.** Execute multi-step flows as one daemon-side operation — click, wait
for the dialog, type, verify the field — with postcondition guards between steps and
failure policies (abort, continue, pause-for-human, fallback). No round-trips between
steps means the world can't change mid-sequence.

**Diff perception.** Read an app's text for a fraction of a screenshot's cost; pass the
observation token back and get only what changed — elements appeared, vanished, values
moved. Screenshots diff the same way: changed-region crops instead of the whole frame,
scroll detection with revealed-edge strips.

**Vision when the tree lies.** About a sixth of Mac apps expose no usable accessibility
tree. A three-tier cascade covers them: accessibility first, then a local
[UI-element detector](https://huggingface.co/kageroumado/rocuronium-ui-detector) — a
5.4 MB CoreML YOLOv11n, ~8 ms per window — plus OCR to turn an icon toolbar into
addressable boxes, then a local VLM for the rest. `read --ocr` and `find --ocr` return the
parsed rows, and `groundedBy` on every row says which tier answered.

## Commands

| | Verbs |
|---|---|
| **Observe** | `status` `diag` `apps` `windows` `find` `read` `map` `wait` `screenshot` `activity` |
| **Act** | `type` `click` `key` `shortcut` `menu` `scroll` `statusitem` `launch` `activate` |
| **Cursor** | `move` `drag` (hardware — takes the real cursor, presence-gated) |
| **Orchestrate** | `plan` (multi-step with guards) |
| **Windows** | `resize` `window` (fullscreen, minimize, zoom) `space` (Mission Control Spaces) |
| **Isolate** | `display` (virtual display lease) `park` (move window to it) |
| **Agent session** | `session` `enable` · `start` · `stop` · `status` — a second macOS user, off-console, with its own cursor; a dead-man's switch ends it when the console daemon stops vouching for it (MCP: `status` and `stop` only) |
| **Meta** | `busy` (hold the presence overlay up while working) `demo` (practice window) `request-capture` `mcp` `guide` (the agent skill baked into the binary) `version` |

Desktop commands accept `--desktop agent` (CLI) or `desktop: "agent"` (MCP) to use the
running agent account. The default is `current`. A plan uses one desktop throughout;
agent targeting verifies the account and off-console login and refuses an unavailable
session. Screenshots are copied back to readable local paths. Session setup and lifecycle
commands remain on the owning desktop.


One coordinate frame everywhere: points, origin at the top-left of the main display.
`rocuronium --help` lists every flag; each MCP tool carries its own contract in its description.

## Safety model

Two invariants hold for every action:

1. **The cursor is never taken without opt-in.** Ghost delivery (accessibility writes,
   per-process posted events) is the default. Hardware input — the path that moves the
   real cursor — requires an explicit flag and is refused while a human is present, while
   the screen is locked, or while another window covers the target.

2. **Every action returns evidence.** The three verdicts (`confirmed` / `noEffect` /
   `unverifiable`) are the contract. The system exists because `AXSetValue` reports
   success on WebKit while changing nothing, `AXPerformAction` reports success on
   background menus that were never validated, and posted wheel events are silently
   ignored by every modern toolkit.

The emergency stop (Ctrl+Option+Shift+Escape) halts everything within one cursor sample.
Resume is a button in the menu bar popover — no socket command can clear the halt.
