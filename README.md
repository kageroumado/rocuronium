# rocuronium

**Drive this Mac without taking the cursor.**

A menu bar daemon that lets an AI agent see and operate macOS — read text, click buttons,
type, scroll, drag, draw — while the human keeps their cursor, their focus, and a kill
switch. Every action returns **evidence** of what observably happened, because
accessibility APIs routinely lie about success.

## What makes it different

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

## Install

```bash
brew install kageroumado/tap/rocuronium
```

Or download the DMG from [Releases](https://github.com/kageroumado/rocuronium/releases).

Grant **Accessibility** (required) and **Screen Recording** (for screenshots and
`scroll --until-text` OCR) in System Settings > Privacy & Security.

## Quick start

```bash
rocuronium status                          # is the daemon running, what can I see
rocuronium read --app TextEdit             # dump the app's text via accessibility
rocuronium click --app Safari --label Done # click a button without touching the cursor
rocuronium type --app Notes --text "hello" # type into the focused field
rocuronium screenshot --app Finder         # capture a window (occlusion-proof)

rocuronium mcp                             # start the MCP server (stdio)
rocuronium guide                           # print the full operator manual
```

## MCP

Add to your Claude Code config:

```json
{
  "mcpServers": {
    "rocuronium": {
      "command": "/Applications/Rocuronium.app/Contents/Resources/rocuronium",
      "args": ["mcp"]
    }
  }
}
```

All verbs are exposed as MCP tools with the same names and arguments.

## Commands

| | Verbs |
|---|---|
| **Observe** | `status` `diag` `apps` `windows` `find` `read` `wait` `screenshot` `activity` |
| **Act** | `type` `click` `key` `shortcut` `menu` `scroll` `statusitem` `launch` `activate` |
| **Cursor** | `move` `drag` (hardware — takes the real cursor, presence-gated) |
| **Orchestrate** | `plan` (multi-step with guards) |
| **Isolate** | `display` (virtual display lease) `park` (move window to it) |
| **Meta** | `guide` `demo` (practice window) `request-capture` `mcp` |

One coordinate frame everywhere: points, origin at the top-left of the main display.
`rocuronium --help` lists every flag; `rocuronium guide` is the full contract.

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

## Documentation

- `rocuronium guide` — the full operator manual (also at [`Docs/GUIDE.md`](Docs/GUIDE.md))
- [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md) — system design (11 sections, stable numbering)
- [`Docs/INTERFACE-PLAN.md`](Docs/INTERFACE-PLAN.md) — what the agent-facing surface should become next

## License

[MIT](LICENSE)
