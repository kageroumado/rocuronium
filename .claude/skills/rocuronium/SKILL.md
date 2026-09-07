---
name: rocuronium
description: Drive this Mac's UI from an agent — read the screen as text, click, type, scroll, drag, press menus, capture windows — without taking the cursor or changing the frontmost app, with evidence on every action. Use when asked to control macOS, read/click/type in a Mac app, automate a desktop workflow, inspect the accessibility tree, screenshot or wait on a window, park a window on a virtual display, or run any rocuronium verb (status, read, find, click, type, key, menu, shortcut, scroll, wait, screenshot, move, drag, park, plan).
---

# rocuronium

Rocuronium lets an agent see and operate macOS. Two words carry the design:

- **Ghost** delivery reaches an app through accessibility and per-process posted events. It never moves the cursor and never changes the frontmost app, so it is safe while a human is at the keyboard. This is the default.
- **The sting** is real hardware input on the console. It takes the cursor, is opt-in per call (`--allow-hardware-input`), and is refused while someone is present.

Every reply says which side delivered the action and, through a computed `verdict`, what observably happened. **Trust `verdict`, never the exit code or the summary.**

## Setup

- The signed **Rocuronium.app** must be running (it holds the Accessibility + Screen Recording grants and does all the work). The CLI and MCP server are thin clients that speak to it over a unix socket.
- CLI: `rocuronium <verb> …`. Full flag reference: `rocuronium --help`.
- MCP: register `rocuronium mcp` (stdio); every verb below is exposed as a typed tool with the same name and arguments, and each tool's description carries its own contract.
- First run needs Accessibility granted (check with `rocuronium status`); Screen Recording is needed only for screenshots, OCR, and vision (`rocuronium request-capture` fires the prompt).

## The loop

    status                                   can I see, is anyone here, am I halted
    read --app X                             what is on screen, as text, with a token
    find --app X --label Y [--role button]   which element, where
    click / type / key / menu / scroll       act, ghost first
        → verdict                            confirmed · noEffect · unverifiable
    read --app X --since <token>             what changed, and only that
    wait --app X --label Z                   block until the world catches up

One coordinate frame (points, origin top-left of the main display), one JSON reply shape, one ambiguity rule (ambiguity is refused, never guessed), and a verdict on every act.

## The three verdicts

- **confirmed** — something observably changed (read-back matched, a frame or scroll bar moved, pixels changed in a still window, the window count moved, a tree element appeared/vanished/changed, or the process exited after a quit-shaped press). Proceed.
- **noEffect** — the call reported success and nothing changed. This is the verdict the tool exists for (WebKit's `AXSetValue` lies; background AppKit menus never validate; wheel events are ignored). **Do not retry harder — change mechanism** (read the `referral`, `activate` the target, `park` it, verify through `read --since`).
- **unverifiable** — nothing to read back and pixels could not testify. **Do not retry blindly** — the action may have landed, and a retry types it twice. Verify through another channel first.

→ Full reply contract (all fields, the tentacle ladder, the tree-diff channel, example replies): **reference/reply-contract.md**

## Verb catalog

**Observe** — `status`, `diag`, `apps`, `windows --app X`, `find`, `read`, `wait`, `screenshot`, `activity`.
**Act (ghost-first)** — `type`, `click`, `key`, `shortcut` (presses the menu item bound to keys), `menu` (by title path), `scroll`, `statusitem`, `launch`, `activate`, `plan`.
**Windows** — `resize` (ghost AX resize/move), `display <acquire|release|status>`, `park`.
**Cursor paths (take the real cursor, presence-gated)** — `move`, `drag`.

→ Targeting (`--app`, the `--label` match tiers, icon-only buttons, `--window`, ambiguity) and the observe verbs in depth: **reference/targeting-and-observing.md**
→ The acting verbs in depth (type/click/key/shortcut/menu/scroll semantics, cursor paths): **reference/acting.md**
→ When the tree is empty — the three vision tiers (accessibility → detector+OCR → local VLM): **reference/vision.md**
→ `plan`: daemon-side multi-step sequences with guards and failure policies: **reference/plans.md**

## Safety and presence

- Ghost verbs (tentacles 0–3) are the default and are safe while a human is present. Cursor-taking verbs (`move`, `drag`, `activate`, `key`/`click` with hardware input) are **refused while a human is present or the screen is locked** unless you pass `--confirm` / `--allow-hardware-input`.
- Every reply carries `presence` (`state`, `mayTakeCursor`, `canSee`, `advice`). A human arriving mid-task is visible on the next answer.
- **⌃⌥⇧⎋ is the emergency stop.** It halts the engine mid-action. Afterward every acting/perceiving verb is refused with "halted by the human"; `status`/`activity` still answer with `halted: true`. **Resume is a button in the menu-bar popover and nothing else — no socket verb can clear the halt.** If your verbs are suddenly refused with that message, stop and wait; do not look for a workaround.

→ The refusal catalog (each refusal, the flag that permits it, why it exists) and the presence model: **reference/presence-and-refusals.md**
→ Isolation — the virtual display as a lease, `park`, the park-then-hardware pattern: **reference/isolation.md**

## Environment facts that trip agents

- **Display asleep is blindness; a locked screen is not.** When the display sleeps every tree collapses to the app element — perception verbs answer "I cannot see", acting verbs wake it first. A locked screen with an awake display is harmless: full trees, ghost input works, only hardware input is refused.
- **Background apps**: ghost delivery is dependable for accessibility writes and unicode text, best-effort for menu presses (AppKit never validates background menus). When the verdict matters on a background AppKit app, `activate` it first.
- **Electron/Chromium ignore posted keycodes** — `type` (unicode) and `shortcut` (menu item) work; a bare `key` keycode does not.
- **A press that quits/restarts its app** verifies by the process exiting, reported `confirmed`; check `apps` before retrying anything quit-shaped.

→ The rest (the display hold, the demo stage for practice, "could not reach Rocuronium.app"): **reference/environment.md**
