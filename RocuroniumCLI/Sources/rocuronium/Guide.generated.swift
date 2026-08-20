// Generated from README.md by Scripts/embed-guide.sh — edit the README, not this.
enum Guide {
    static let text = ##"""
# rocuronium — drive this Mac without taking the cursor

A menu bar app, a CLI, and an MCP server that let an agent see and operate macOS while a
human keeps their cursor, their focus, and their trust. Every action returns **evidence**
— what observably happened, verified by read-back or pixels — because return codes lie
(`AXSetValue` reports success on WebKit while changing nothing).

This file is the operator's manual. It ships inside the binary: `rocuronium guide`
prints it, so an agent holding nothing but the CLI can learn the contract.

## The shape of things

`Rocuronium.app` holds the Accessibility grant and does all the work; the `rocuronium`
CLI (at `Rocuronium.app/Contents/Resources/rocuronium`) is a thin client that speaks
JSON over an authenticated local socket. `rocuronium mcp` serves the same verbs as MCP
tools. Add `--json` to any command for the full reply.

    status · diag · guide                          what can I do right now
    apps · windows · find · read · wait            observe (read-only)
    launch · activate                              lifecycle
    type · click · scroll · shortcut · menu · key  act
    display · park · screenshot                    isolation + pixels

Targeting: `--app` takes a name or a bundle id. Two running apps with the same name (a
debug and a release build, say) are refused with both candidates listed — pass the
bundle id. A label that matches elements of several roles is likewise refused; pass
`--role` (e.g. `--role button`) to say which one you meant. Label matching tries labels
first and element *values* as the fallback, so text you saw in `read` output is findable
and scrollable-to even when it exists only as a value.

## Evidence: the three verdicts

Every acting verb replies with a `verdict`. Trust it over the exit code, over the
summary, over your expectations.

- **confirmed** — something observably changed: a read-back matched what was written, a
  scroll bar moved, an element's frame moved, pixels changed in a window that was
  provably still, the target's on-screen **window count** moved (the read-back for
  presses whose consequence is a window or sheet appearing or vanishing — File ▸ New,
  Cancel, Escape on a dialog, a close button — which element-rect and pixel evidence are
  structurally blind to), or the target process exited after a quit-shaped press. Proceed.
- **noEffect** — the call reported success and *nothing observably changed*. This is the
  most important verdict in the system: it is how WebKit's lies, background AppKit
  menus, and ignored wheel events surface. Do not retry the same call harder; change
  mechanism (see the referral, activate the target, or park it).
- **unverifiable** — the target exposes nothing to read back and pixels could not
  testify (no capture permission, or the window animates on its own). **Do not retry
  blindly**: the action may well have landed, and a retry types it twice or presses it
  twice. Verify through another channel first — `read` the state, take a `screenshot`.

Replies also carry `attempts` (each ladder rung tried and why it fell through),
`cursorMovedByUs` / `focusTakenByUs` (the promises, as measurements), and sometimes a
`referral` — a structured pointer to the channel that *can* reach a target the ghost
rungs cannot (web page content wants `refrax-ctl`, CDP, or Safari's own scripting). A
referral means "compose that tool yourself"; rocuronium deliberately does not shell out.

## Presence: who else is at this Mac

Every reply includes a `presence` block: `state` (`present` / `idle` / `away` /
`unknown`), `canSee`, `mayTakeCursor`, and a sentence of advice. Unknown is treated as
present, because that is the cautious reading.

What gates on it:

- **`activate`** — refused unless `away` (or `confirm: true`): raising an app takes
  focus out of a human's hands. Even when permitted, it can honestly fail: macOS
  cooperative activation sometimes declines to promote an **accessory (menu-bar /
  LSUIElement) app** while a regular app holds focus — the reply reads back the truth
  ("did not land — X is still frontmost") rather than claiming success. `open` on an
  accessory app never activates it either. When an un-activatable app must be frontmost
  (WebKit content ignores cursor motion in inactive windows), retry after the focused
  app is quit or deactivated, or drive the app through its own automation channel.
- **`move` / `drag`** — same gate as `activate`: they always take the real cursor
  (there is no ghost rung for motion — measured), so they are refused unless `away` or
  confirmed, and refused outright while the screen is locked or the action point is
  covered by another app's window.
- **Hardware input** (`allowHardwareInput`) — the advice tells you whether taking the
  cursor is acceptable; the engine additionally refuses it outright while the screen is
  locked or the aim point is covered by another app's window.
- Everything else is ghost-safe by construction: rungs 0–3 never move the cursor and
  never change the frontmost app, so they are fine while a human is typing.

## Display asleep is blindness; screen locked is not

When the display sleeps, **every app's accessibility tree collapses** — windows vanish,
fields disappear, and a naive tool concludes "this app exposes nothing" and reports
confident nonsense. Rocuronium refuses instead: perception verbs answer "I cannot see"
and acting verbs wake the display first (rung 0).

A locked screen with an awake display is harmless: full trees are readable and ghost
input works. Only hardware input is refused there — synthetic keystrokes would land in
the login window's password field.

## The refusal catalog

Refusals are rails, not failures. Each one names a flag, and passing the flag is a
deliberate, legitimate act when the situation genuinely calls for it:

- **`submit`** (`type`) — a newline or tab in a composer sends the message or moves
  focus. Refused by default so text can never submit by accident; pass `submit: true`
  when sending is the point. An absent `text` is likewise refused — pass `""` explicitly
  to clear a field, because clearing is unrecoverable.
- **`confirm`** (`shortcut`, `menu`) — every app's menu bar includes the Apple menu, so
  `cmd+shift+q` resolves to "Log Out" from any target. Items that end the session are
  refused only under **Apple ▸** (an app menu's "Restart to Update" restarts the app,
  not the Mac); data-destroying items (trash, erase) are refused wherever they appear.
  The consequence is named; `confirm: true` presses anyway. Use `resolveOnly: true` to
  audit what a shortcut or path would press, before the fact.
- **`confirm`** (`activate`) — see presence above.
- **`allowHardwareInput`** (`type`, `click`) — permits rung 4, the one mechanism that
  moves the real cursor. Legitimate when nobody is present and the ghost rungs have
  demonstrably failed; the evidence will say `cursorMovedByUs: true` and the reply
  refuses if another window covers the target (see the park pattern).
- **lease** (`park`) — parking a window onto the virtual display without holding a lease
  is refused: the display could vanish out from under the window and strand it where no
  one can see it. `display acquire` first; the lease has a reason and an expiry so a
  crashed agent cannot leak a screen.
- **`timeout` > 25** (`wait`) — the socket cancels requests at 30 s. A timed-out wait
  replies `callAgain: true`; loop on it rather than asking for a longer block.

## The park-then-hardware pattern

Rung 4 clicks whatever window is topmost at the coordinate — unlike ghost rungs, which
reach a process through any occlusion. So a hardware click on an occluded target is
refused with the occluder named. The reliable sequence when hardware input is truly
needed:

    display acquire --reason "why" → park --app X → act with --allow-hardware-input
    → park back (the reply carried the window's previous position) → display release

Windows on the virtual display occupy none of the pixels a human sees, which satisfies
both the occlusion check and the politeness contract.

## Reading and scrolling, honestly

`read` dumps an app's text through accessibility — orders of magnitude cheaper than a
screenshot, and it works behind a locked screen. Bounded (elements, characters, and an
18 s wall clock) with truncation always reported: "stopped looking" and "nothing there"
are different answers. A web area that yields no text is reported as **hidden, not
blank**, with a referral to the channel that can read the DOM.

`scroll` prefers `label`: the app is asked to bring that element into view
(`AXScrollToVisible`), confirmed by the element's frame moving — the one cursor-free
scroll that works (measured; posted wheel events are ignored by every toolkit, so a bare
`--dy` will usually earn an honest `noEffect`). `--to 0..1` writes the scroll bar where
one exists — found by attribute or, for the overlay scrollers modern AppKit hides from
the attribute, by role walk. Safari's web content exposes a writable bar (measured:
`--to` round-trips confirmed); Chromium and Electron never expose one.

`wait` polls for an element (`--gone` for disappearance) and is the right primitive
after `launch`, after a click that opens a dialog, or before reading a slow view.

Label queries (`find`, `click`, `type`, `scroll`, `wait`, `read --label`) **never match
menu items** — the menu bar is excluded from label walks. Menu items are the right match
for nothing except `menu` and `shortcut`, which resolve them properly; a closed menu
item's frame is a meaningless 0×0 rect at the screen corner, and matching one turned
"wait for the page to load" into a false positive on a History-menu entry (measured).

## Keys that are neither text nor shortcuts

`key` posts a bare named key — escape, return, tab, space, delete, arrows, home/end,
page up/down — with optional modifiers (`shift+tab`, `cmd+down`). It exists for the gap
the other input verbs leave: committing a focused field wants a plain Return, which
`type` (text only) and `shortcut` (menu items only) cannot send. Per-pid, no cursor, no
focus change. Measured reach: keys land in the app's **focused text control** — `key
return` in a focused address bar commits navigation — but sheet key-equivalents do
**not** actuate (`key escape` will not cancel a save sheet, even frontmost; press the
sheet's button instead: `click --label Cancel --role button`). Electron/Chromium ignore
posted keycodes entirely. An `unverifiable` verdict means exactly that, not "retry".

## Cursor paths: move and drag

`move` glides the **real** cursor along a path and leaves it on the destination; `drag`
does the same with a button held (down at `--from`, up at `--to`). There is no ghost
variant and there will not be one: per-pid posted motion is dropped wholesale by the
window server (measured 2026-08-20 — tracking areas, SwiftUI `onHover`, WebKit hover,
content drags and title-bar drags all stayed silent, background and frontmost alike).
Because these verbs always take the physical cursor, they are presence-gated like
`activate`: refused while a human is present unless `--confirm`.

The path is a straight line, or a smooth curve **through** `--via` waypoints — built for
hover-intent chains: glide onto the nav item, pause, then curve down into the flyout
without leaving the hover region. `--duration` (seconds) and `--easing` shape the timing;
the default is a distance-based duration with ease-in-out, which is what human motion
looks like to velocity-watching UI. The destination can be an element
(`--app X --label Y`) instead of coordinates.

Evidence: the cursor's actual end position is read back (`confirmed` means the pointer
provably stands on the destination), and with `--app` the reply carries the target's
window count before/after — a flyout or menu appearing is a window appearing, the
consequence element-evidence is blind to. Measured caveats, all reported in replies:
hover lands on whatever window is **topmost** at the point (occlusion refused when
`--app` is given — park or activate first); WebKit/WKWebView pages ignore all motion
while their app is inactive (`activate` before web hover); a drag aborted by a mid-path
lock or cancel releases its button where it stopped, never leaving it held.

## Actions that close their own app

A press that quits or restarts its app (Quit, an updater's "Restart to Update") can
never verify through the app — every read-back channel needs a live process. The engine
treats the target process *exiting* as the read-back: the verdict is `confirmed` with
the exit named. An unverifiable press on an app that is still running really is
unverified; do not retry a quit-shaped action without checking `apps` first.

## Background apps

Ghost delivery to background apps is dependable for AX writes and unicode text, and
best-effort for menu presses: background AppKit apps never validate their menus, so a
press can return success, do nothing, and be reported `unverifiable` with the item's
disabled state noted. When the verdict matters and the target is AppKit-in-background,
`activate` it first (gated, honest) — that is exactly what the verb exists for.
"""##
}
