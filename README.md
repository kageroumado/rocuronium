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
    statusitem                                     menu bar status items
    activity                                       what happened this session
    display · park · screenshot                    isolation + pixels

Targeting: `--app` takes a name or a bundle id. Two running apps with the same name (a
debug and a release build, say) are refused with both candidates listed — pass the
bundle id. Two instances of the same *bundle id* (`open -n`) have exactly one
unambiguous address: `--pid`, which every app-taking verb accepts and which overrides
`--app`. A label that matches elements of several roles is likewise refused; pass
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

## The visible agent: overlay, ⌥⎋, and the activity log

Cursor-taking work is visible work. Whenever a command opts into hardware input, and for
`move`/`drag` always (they take the real cursor by construction), the app shows the
presence overlay: a whisper of a tint over the desktop (readable from across the room,
never enough to hide anything), an opaque bezel that narrates each action in
evidence-verdict language with the session's elapsed time (drag it wherever it bothers
you least — the position is remembered), and the jellyfish escorting the cursor while a
command is in flight, then drifting home to perch beside the bezel. Before each hardware
click a sigil charges at the aim point for ~600 ms — that wind-up is a deliberate
interrupt window, not decoration. The overlay lingers ~15 s after the last command, then
fades. A "show overlay for every action" toggle in the menu bar popover extends it to
ghost-rung commands too.

**The cursor stays negotiable.** During a `move`/`drag`, a brushed mouse is absorbed —
the glide bends elastically and eases back on path, still landing on the destination —
while sustained deliberate motion (about a quarter second of it) makes the gesture yield:
the button is released, the reply says "yielded to the hand on the mouse", and the cursor
is yours. ⌥⎋ remains the hard stop.

**⌥⎋ is the emergency stop.** While the overlay is visible, Option+Escape halts the
engine mid-action: a cursor trace aborts within one sample (a held drag button is
released where it stopped), typing stops mid-character, walks bail out. After the halt,
every acting and perceiving verb is refused with "halted by the human (⌥⎋) — resume from
the Rocuronium menu bar"; `status` and `activity` still answer and report
`halted: true`. **Resume is a button in the menu bar popover and nothing else** — no
socket verb can clear the halt, so an agent cannot un-halt itself. If your verbs are
suddenly refused with that message, stop and wait for the human; do not retry and do not
look for a workaround.

`activity` returns the session's recent actions (last 200) with their verdicts — the
same record the human sees in the menu bar popover, so both sides of the session are
reading one log.

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
- **lease** (`park`) — parking always happens under a lease, so the display cannot
  vanish out from under the window and strand it where no one can see it. With no lease
  in force, `park` takes an **auto-lease** (reason recorded from the command, id in the
  reply, visible in `display status`) that releases itself when its last parked window
  is returned or closes; teardown sweeps parked windows home first, always. Attaching a
  display while a human is at the keyboard is a visible event, so that step is refused
  without `allowDisplayAttach` unless presence reads away. `display status` also lists
  **strays** — windows on the virtual display nobody parked (a saved frame restored
  there, a second window of a parked app); release warns about them and sweeps them to
  the main screen.
- **`timeout` > 25** (`wait`) — the socket cancels requests at 30 s. A timed-out wait
  replies `callAgain: true`; loop on it rather than asking for a longer block.

## The park-then-hardware pattern

Rung 4 clicks whatever window is topmost at the coordinate — unlike ghost rungs, which
reach a process through any occlusion. So a hardware click on an occluded target is
refused with the occluder named. The reliable sequence when hardware input is truly
needed:

    park --app X (auto-leases the display) → act with --allow-hardware-input
    → park back (the reply carried the window's previous position; the auto-lease
      releases itself and the display goes away)

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

`scroll --until-text <string>` is the deterministic form for content the tree does not
expose: each step captures the target's window (window-true, occlusion-proof), OCRs it
locally, and stops the moment the string is legible — no over- or undershoot, because
the loop terminates on sight rather than on a guessed distance. Needs Screen Recording.
The stepper is the scroll bar where one exists (step sized from the bar's thumb with
overlap, so a screenful can never skip past the target between frames); `--dy`'s sign
sets the direction. The reply carries `foundAt` — the sighting's screen rectangle, ready
for `click --x --y` at its center — and `callAgain: true` when the step budget ran out
with document left. Two frames with identical legible text end the loop honestly: the
end of the content, or a toolkit that ignores the mechanism (the referral says which
channel can reach it).

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

A bare start→end `move` follows a naturally bowed arc — a randomized few-percent
perpendicular bow, because human motion is never a ruler line; `drag` paths stay exact
(their geometry is semantic — sliders, selections), and explicit waypoints are honored
as given. The path can also be a smooth curve **through** `--via` waypoints — built for
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

## Status items and menu buttons

`statusitem --app X` lists an app's menu bar status items; `--press` opens one's menu or
popover by `AXPress`, cursor-free. Status items live in a separate extras menu bar that
no window walk or `find` reaches, so this verb is the only ghost path to a MenuBarExtra.
With several items, `--label` picks one; pid-scoping keeps two instances of one bundle
id distinguishable. Evidence is the target's window count — a popover opening is a
window appearing — because the press call itself can block in menu tracking and return
an error code for a press that fully worked.

Controls that expose only `AXShowMenu` (menu buttons, and the remote elements System
Settings panes host inside opaque provider groups) are clicked like any button: the
press rung performs the show-menu action when no press action exists, and the menu
appearing is the window-count consequence to watch for. Two measured caveats on the
System Settings case: the opened menu's window belongs to the pane's *appex*, not the
app you targeted, so the window-count read-back can miss it and the verdict stays
`unverifiable` for a menu that visibly opened — verify with a region `screenshot` when
it matters. And once open, such a menu is not dismissible by any ghost mechanism
(posted Escape to host and appex both no-op — menu tracking runs its own event loop;
re-pressing does not toggle): choose an item, or quit the host app to tear it down.

## The demo stage

`demo` opens a deterministic practice window at (720, 200), 560×720 — fixed position,
stable labels, every control instrumented with a counter, so any verb can be exercised
and *verified* without borrowing your real windows. Drive it with `--app Rocuronium`: a
click target ("Tap Target" → "clicks: N"), a text field ("Type Here" → echo), a switch, a
slider, a hover pad whose tracking fires even in the background ("hovers: N"), a
120-row scroll flume whose needle is "Row 87 · the needle", and a gallery of the
jellyfish's states plus the charge sigil. `demo reset` (the default) zeroes the counters;
`demo show` keeps state; `demo hide` closes it. Also openable from the menu bar popover.

## The display hold

While an agent session is active (any perceiving or acting command), the app holds the
display awake — through Adrafinil's display-class holds (`adrafinil acquire --display`)
when its CLI is installed, or a process-local assertion otherwise — and releases after a
few quiet minutes. `status` reports it as `displayHold: adrafinil | internal | none`.
Adrafinil's own pause, idle-release, and thermal cutouts outrank the hold, and a hold
deliberately stops at the lock screen: locked-but-awake is fully readable, and the lock
itself is Dantrolene's decision, not ours. Measured 2026-08-22: the wake and the hold do
**not** reset `HIDIdleTime`, so presence readings stay honest about whose activity is
whose.

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
