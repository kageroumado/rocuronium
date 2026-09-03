// Generated from Docs/GUIDE.md by Scripts/embed-guide.sh — edit the guide, not this.
enum Guide {
    static let text = ##"""
# Operator manual

The reference for an agent driving this Mac through rocuronium. It ships inside the CLI
(`rocuronium guide`), so a session holding nothing but the binary can learn the contract.
Kept in `Docs/GUIDE.md`; `Scripts/embed-guide.sh` bakes it into the CLI at release.

Two words carry the whole design. **Ghost** delivery reaches a process through
accessibility and per-process posted events: it never moves the cursor and never changes
the frontmost app, so it is safe while a human is typing. **The sting** is real hardware
input on the console: it takes the cursor, it is opt-in per call, and it is refused while
someone is at the Mac. Everything below is a verb on one side of that line or the other,
and every reply says which side it was delivered on and what observably happened.

## The loop

    status                                   can I see, is anyone here, am I halted
    read --app X                             what is on screen, as text, with a token
    find --app X --label Y [--role button]   which element, where
    click / type / key / menu / scroll       act, ghost first
        → verdict                            confirmed · noEffect · unverifiable
    read --app X --since <token>             what changed, and only that
    wait --app X --label Z                   block until the world catches up

One coordinate frame, one JSON shape, one ambiguity rule, and a verdict on every act.
The sections follow the loop: contract, coordinates, targeting, observing, acting,
vision, cursor paths, plans, then the rails (presence, refusals, isolation) and the
environment facts that trip agents.

## 1. The reply contract

Every command answers one JSON object (`--json` prints it; MCP returns it verbatim).
`ok` is the exit code: `true` exits 0. Acting verbs carry these fields:

| field | meaning |
|---|---|
| `verdict` | `confirmed` · `noEffect` · `unverifiable` — see below. Trust it over `ok`, over `summary`, over your expectations. |
| `tentacle` | which delivery mechanism landed the action: `displayWake`, `accessibility`, `postedEvent`, `appAutomation`, `hardwareInput` |
| `attempts[]` | each tentacle tried, with `outcome` — why it fell through or how it verified. Read this when the verdict surprises you. |
| `readback` | the value read back after the act, when the target exposes one |
| `pixelDelta` | fraction of pixels that changed in the watched rectangle, when captured |
| `cursorMovedByUs` / `focusTakenByUs` | the two ghost promises, as measurements. `cursorMovedByUser` is a human hand on the mouse, not a warning. |
| `presence` | `{state, mayTakeCursor, canSee, offConsole, advice}` — on every reply, so a human arriving mid-task is visible on the next answer |
| `referral` | `{channel, reason, advice}` when no tentacle can reach the target and something else can (web content wants `refrax-ctl`, CDP, or Safari scripting). A referral means "compose that tool yourself". |
| `suggestion` | a machine-readable next move on a refusal (the occlusion refusal suggests `park`) |
| `groundedBy` | `detector` or `vlm` when the target's coordinates came from vision rather than the accessibility tree (§6) |
| `treeChanges` / `treeDelta` | on `click`/`shortcut`/`menu`: how many window elements moved across the act, and the rendered diff of them. Any change confirms the act on its own — the channel that sees a sibling value ticking when pixels cannot. Absent when the tree was too large to walk twice (pass `--observe`) or truncated. |

**The tentacles**, in the order they are tried. Each is verified before the next is
attempted; a return code alone never counts.

| # | wire name | mechanism | cursor / focus | verified by |
|---|---|---|---|---|
| 0 | `displayWake` | wake a sleeping display first | — | display awake |
| 1 | `accessibility` | `AXSetValue`, `AXPress`, `AXShowMenu` | never | read-back, window count, pixels |
| 2 | `postedEvent` | `CGEvent.postToPid` with a unicode payload | never | read-back, focus delta, pixels |
| 3 | `appAutomation` | a referral, never an adapter | never | names the channel |
| 4 | `hardwareInput` | the sting: real events on the console | **takes both** | read-back, pixels, occlusion pre-check |

**The three verdicts.**

- **confirmed** — something observably changed: a read-back matched what was written, a
  scroll bar or element frame moved, pixels changed in a window that was provably still,
  the target's on-screen window count moved (File ▸ New, Cancel, Escape on a dialog, a
  close button), an element in the window appeared, vanished, or changed value across the
  act (the tree-diff channel — see below), or the process exited after a quit-shaped
  press. Proceed.
- **noEffect** — the call reported success and nothing observable changed. This is the
  verdict the system exists for: WebKit's `AXSetValue` lies, background AppKit menus
  never validate, wheel events are ignored. Do not retry the same call harder. Change
  mechanism: read the referral, `activate` the target, `park` it, or verify through the
  tree (below).
- **unverifiable** — the target exposes nothing to read back and pixels could not
  testify. **Do not retry blindly**: the action may have landed, and a retry types it
  twice. Verify through another channel first.

**Pixels are blind to small consequences — so the tree diff is a built-in channel.**
Measured on the demo stage: a ghost click on "Tap Target" moves the button's own pixels
back to rest and the counter that changed is one glyph in a 560×720 window, under the
noise floor, so `pixelDelta` reads 0. `click`/`shortcut`/`menu` therefore walk the
window's accessibility tree before and after the act and diff them: the click reports
`treeChanges: 1`, `treeDelta: "value changed: AXStaticText 'clicks: 0' → 'clicks: 1'"`,
and that alone confirms it. The walk is one bounded pass and is skipped on a tree too
large to walk twice (Discord-sized) unless you pass `--observe`; the diff is emitted even
on an already-confirmed act, because "what changed" is worth more than "something did".
Confirm-only: a still tree never *refutes* a press, since the consequence can land in a
popover or a second window the walk never reached. `read --since` remains the way to ask
the same question by hand across any two moments.

Two example replies, abbreviated:

    click --app Rocuronium --label "Tap Target" --json
    { "ok": true, "verdict": "confirmed", "tentacle": "accessibility",
      "attempts": [ {"tentacle":"displayWake","outcome":"alreadyAwake"},
                    {"tentacle":"accessibility","outcome":"press accepted"} ],
      "pixelDelta": 0, "treeChanges": 1,
      "treeDelta": "value changed: AXStaticText 'clicks: 0' → 'clicks: 1'",
      "readback": "the window's accessibility tree changed (1 element(s))",
      "cursorMovedByUs": false, "focusTakenByUs": false,
      "summary": "click → AXButton 'Tap Target' [accessibility] ok" }

    type --app Rocuronium --label "Type Here" --text hello --json
    { "ok": true, "verdict": "confirmed", "tentacle": "accessibility",
      "attempts": [ …, {"tentacle":"accessibility","outcome":"confirmed by read-back"} ],
      "readback": "hello", "summary": "setText(\"hello\") → AXTextField 'Type Here' [accessibility] ok" }

Errors are `{ "ok": false, "error": "<sentence>" }`, plus `presence` on most, `suggestion`
when there is a next move, and `halted: true` after ⌃⌥⇧⎋. Refusals name the flag that
would permit the act (§10).

## 2. Coordinates

One frame everywhere: **points** in the global display space, origin at the **top-left of
the main display**, x to the right, y downward. A display to the right of the main one
starts at x = main width; a display above it has negative y. `find` and `windows` frames,
`--x --y`, `--from --to --via`, `foundAt`, `screenshot`'s `rect` and `regions[].rect`, the
demo stage at (720, 200): all the same frame. The only pixels are a PNG's `width` and
`height`, which are 2× the point size on a Retina display. A rect block is always
`{x, y, w, h}`.

## 3. Targeting

**Which app.** `--app` takes a localized name or a bundle id; bundle ids match exactly and
win. Two running apps with the same name (a debug and a release build) are refused with
both listed: pass the bundle id. Two instances of one bundle id (`open -n`) have exactly
one address, `--pid`, which every app-taking verb accepts and which overrides `--app`.

**Which element.** Three locators, and no verb falls back from one to another, so you
always know which mechanism answered:

- `--label <text>` — case-insensitive substring match, in one walk of the app's windows.
  Matching consults title, description, placeholder, then role description, then (as the
  last tier, only when no label matched) the element's value, so text you saw in `read`
  output is findable even when it exists only as a value. **What comes back is split from
  what is matched**: a row's `label` is the element's own name only (title / description /
  placeholder) and is empty when it has none, with `roleDescription` ("button"), `help`
  (the tooltip, `AXHelp` — an icon button's name without a hover), `identifier`
  (`AXIdentifier`, SwiftUI's `accessibilityIdentifier`, often the symbol name), `subrole`,
  and `near` (the nearest labelled sibling and the bearing to it, "right of 'Undo'") in
  their own fields. So an **icon-only button is `label:""`, `roleDescription:"button"`** —
  match on its help, identifier, or near, or list `find --role button` and aim by frame.
- `--role <r>` narrows a label match when several roles share the text (a button and a
  menu item both named "Restart"). `button` and `AXButton` both work.
- `--x <n> --y <n>` hit-tests the point. For a press, a hit on a plain group ascends to
  the enclosing pressable control (SwiftUI wraps buttons this way).
- Neither given: the app's **focused element**. That is where `type` goes by default.
- `--window <title substring>` scopes the verb to one of the app's windows instead of its
  primary one — the answer to two "Untitled" windows, a sheet, or a second document. It
  works on `find`, `read`, `click`, `type`, `wait`, `screenshot`, `move`, `drag`, and
  `park`; ambiguity is refused with the matching titles listed, and a `screenshot` that
  cannot be scoped to the named window refuses rather than widening to the display.

**Ambiguity is refused, never guessed.** A label matching several elements returns the
candidates with their roles; the next move is `--role`, a longer label, or coordinates.
Substring matching means `delete` can name three buttons, and acting on whichever
sorted first is a coin flip on somebody's data.

**Menu items never match label queries.** `find`, `click`, `type`, `scroll`, `wait`, and
`read --label` skip the menu bar; a closed menu item's frame is a meaningless 0×0 rect at
the screen corner, and matching one turned "wait for the page to load" into a hit on a
History-menu entry. Menus belong to `menu` and `shortcut`, which resolve them properly.

**Window scope.** Without `--window` a verb acts on the app's primary window (and
`read --label` on one element's subtree). `--window <title substring>` picks a different
one; `windows --app` lists the titles to choose from.

## 4. Observing

**`status`** — `trusted` (Accessibility granted), `presence`, `idleSeconds`,
`screenLocked`, `displayAsleep`, `canSee`, `mayTakeCursor`, `advice`, `halted`,
`virtualDisplayActive`, `displayHold` (`adrafinil` · `internal` · `none`). Cheap, and it
never pins the display awake, so a monitoring loop may poll it.

**`diag`** — what each permission check actually returns and what a real 16×16 capture
attempt does. Run it before guessing at TCC state. **`request-capture`** fires the Screen
Recording prompt; after a decline it returns instantly forever until
`tccutil reset ScreenCapture glass.kagerou.rocuronium`.

**`apps`** — the running apps a human would see in the Dock: `name`, `bundleID`, `pid`,
`frontmost`, `hidden`.

**`windows --app X`** — `title`, `frame`, `minimized`, `main`, `display`,
`onVirtualDisplay`, `stray` (on the virtual display, parked by nobody), and
`onAnyDisplay: false` for a window stranded where no display reaches.

**`find --app X [--label Y] [--role R] [--ocr]`** — up to **20** matches, each `{role,
label, value, depth, frame}`, plus `elementsVisited` and `truncated`. With only `--role`,
every element of that role; with neither, every editable field. The walk is bounded
(60 000 elements, 18 s wall clock) and truncation is reported: "nothing found" and
"stopped looking" are different answers. When the walk finds nothing and Screen Recording
is granted, `find` **falls back to OCR** automatically; `--ocr` forces it. OCR rows are
`{role: OCRText, label: <text>, frame, groundedBy: ocr}` with `shown`/`total` — text with
screen-point frames for a window whose tree is empty or lying.

    find --app Finder --role button
    AXButton  (button)  @(1448,474)  help 'Back'  near left of 'Path'  depth 7
    AXButton  (button)  @(1448,698)  near right of 'Back'  depth 7
    …
    5 shown · 994 elements visited

**`read --app X [--label Y] [--role R] [--since T] [--ocr]`** — the app's text through
accessibility: static text, field values, button titles, checked states, indented by
depth, with every interactive element's role shown so you know it can be acted on.
Orders of magnitude cheaper than a screenshot, and it works behind a locked screen.
Budgets: 20 000 elements, 30 000 characters, 4 000 per value, depth 40, 18 s; the reply
carries `truncationReason` when one bit. A web area that yields no text is reported as
**hidden, not blank**, with a referral to the channel that can read the DOM. When the
whole-window walk finds no text and Screen Recording is granted, `read` **falls back to
OCR** automatically; `--ocr` forces it. OCR rows come back as `{role: OCRText, value:
<text>, frame}` in reading order (scope `window (OCR)`, `groundedBy: ocr`), with no token
or delta — there is no tree walk to diff.

    read --app Rocuronium
    Rocuronium Demo Stage  [AXWindow]
        Demo Stage
        Tap Target  [AXButton]
        clicks: 0
        Demo Switch: 0  [AXCheckBox]
        Type Here  [AXTextField]
        …
    read window 'Rocuronium Demo Stage' · 985 chars · 151 elements
    token ax95119-3d1a92d3

**Pay for the change, not the frame.** Pass the token back as `--since` and the reply is
the structural delta: elements appeared (grouped under their topmost appeared ancestor,
"appeared: AXPopover 'Save options' containing [AXButton 'Cancel', AXButton 'Save']"),
elements vanished, and values old → new. The daemon keeps a few recent observations per
target; a token that cannot be diffed honestly (evicted, another process, a different
window or scope, a truncated walk, wholesale change) **degrades to the full reply with
`diffNote` naming why**, never to a silently wrong diff.

    read --app Rocuronium --since ax95119-3d1a92d3
    value changed: AXStaticText: 'clicks: 0' → 'clicks: 1'
    1 change(s) in window 'Rocuronium Demo Stage' since ax95119-3d1a92d3
    token ax95119-e5f74fff

**`wait --app X (--label Y [--role R] [--gone] | --for '<guard json>') [--timeout S]`** —
blocks until a condition holds. `--label` (with `--gone` for disappearance) is the sugar
form; `--for` takes the same guard object a `plan` step's `expect` uses (§8), which adds
`window-appears`/`window-vanishes` (by title), `text-visible`/`text-vanishes`, and two
guards written for waiting: `{"type":"quiet","ms":800}` blocks until the window's tree
holds still for that long — how "the view finished loading" is actually detected, since
there is no done event — and `{"type":"token-changed","token":"ax…"}` blocks until the
tree differs from a prior whole-window `read` token ("wait until anything changes").
Default 10 s, at most 25 because the socket cancels requests at 30: a timed-out reply says
`callAgain: true`, so loop rather than asking for a longer block. `ok` mirrors
`satisfied`. The right primitive after `launch`, after a click that opens a dialog, before
reading a slow view.

**`screenshot [--app X | --x --y --w --h] [--path F] [--since T]`** — hands the pixels to
you; your model does the looking. `--app` captures the app's primary window through a
window filter (occlusion-proof, works while parked), a region captures visible pixels,
and with neither the main display is captured. Reply: `path`, `width`/`height` (pixels), `rect`
(points), `token`, `window`. Captures land in the app's `captures` folder and are swept
after 24 h; `--path` must end in `.png`, must not exist, and must be under Desktop,
Downloads, Pictures, `/tmp`, or that folder. With `--since` the reply is changed-region
crops (`regions[] = {rect, path}`, `changedFraction`), or "content scrolled ~N pt" with an
edge-strip crop of what was revealed, or `changed: false`; a wholesale change returns
the full frame with a `diffNote`. `--since` and `--path` are mutually exclusive. Needs
Screen Recording; refused while the display sleeps, because that frame would be black.

**`activity`** — the last 50 acting commands with verdicts, the same record the human
sees in the menu bar popover, plus `halted`. How a session re-orients after a context
reset: both sides of the table are reading one log.

## 5. Acting

Every acting verb is ghost-first and replies with the §1 contract. `--allow-hardware-input`
permits the sting as a last resort on `type`, `click`, and `key`; §10 says when that is
legitimate.

**`type --app X --text T [--label Y] [--submit]`** — through accessibility, `type` **sets
the field's value to `T`**, replacing what was there, and confirms by read-back. When
that write is refused or ignored, it falls through to keystrokes, which **insert at the
caret** after a posted click on the field; `tentacle` in the reply says which happened,
so read it before assuming either semantics. A value that changed but does not match
(smart quotes) is reported `noEffect` and never retried, to avoid duplicating text.
Search fields are special: the read-back confirms but SwiftUI's binding ignores the
write, so it is undone and keystrokes are used. Rails: absent `--text` is refused (pass
`""` explicitly to clear, because clearing is unrecoverable); a newline or tab is refused
without `--submit`, because a newline in a composer sends. Electron accepts unicode
keystrokes and ignores keycodes, so editing operations (clear, select-all) are
accessibility writes there, never keystrokes.

**`click --app X (--label Y [--role R] | --x N --y N)`** — accessibility press (or
show-menu, for menu buttons and the remote controls System Settings panes host) →
posted click → sting if permitted. An **accepted press ends the ladder** even when it
verifies as `unverifiable` or `noEffect`; escalation to posted or hardware clicks
happens only when the element exposes no press action. So a `noEffect` click does not
mean "try harder", it means "look elsewhere for the consequence": `read --since`, the
window list, a region screenshot. Window-count, whole-window pixel, and tree-diff
evidence (`treeChanges`/`treeDelta`, §the verdicts) are added automatically for the
dialog-opening and button-elsewhere cases; `--observe` forces the tree diff on a window
large enough that it would otherwise be skipped.

**`key --app X --keys K [--allow-hardware-input] [--confirm]`** — a bare named key with
optional modifiers: `escape`, `return`, `enter`, `tab`, `space`, `delete`,
`forwarddelete`, `left/right/up/down`, `home`, `end`, `pageup`, `pagedown`;
`shift+tab`, `cmd+down`. The gap between `type` (text only) and `shortcut` (menu items
only). Per-pid, no cursor, no focus. Measured reach: lands in the app's focused text
control (`return` in an address bar commits), but **sheet key-equivalents do not
actuate on the per-pid channel**: `escape` will not cancel a save sheet. Two ways
through: press the sheet's button by label (`click --label Cancel --role button`), or
`key --allow-hardware-input`, a session-level keystroke on the console pipeline, gated
like every hardware verb and additionally requiring the target frontmost because it
lands in global focus. Electron and Chromium ignore posted keycodes entirely.

**`shortcut --app X --keys cmd+a [--resolve-only] [--confirm]`** — resolves the **menu
item** bound to those keys and presses it. No keystroke is sent, which is why it works
on Chromium; it also means a shortcut with no menu item cannot be delivered this way
(use `key`). The reply names `menuItem` ("Edit ▸ Select All"). Dependable on the
frontmost app; in the background, AppKit apps never validate their menus, so the press
returns success and does nothing, foretold by `menuItemReportedDisabled` in the reply.
Verification is selection read-back, then a window-true pixel diff that may only
confirm, never refute (copy changes no pixels).

**`menu --app X --path "File > Export" [--resolve-only] [--confirm]`** — the same press
by title path (`▸` works; case-insensitive; a trailing "…" is optional). Reaches every
command with no shortcut. A path naming a submenu is refused with its items listed.

Both share the hazard rail: every app's menu bar includes the Apple menu, so `cmd+shift+q`
resolves to Log Out from any target. Session-ending items are refused only under
**Apple ▸**; data-destroying items (trash, erase) wherever they appear. `--confirm`
presses anyway; `--resolve-only` audits what would be pressed, before the fact.

**`scroll --app X …`** — four forms, honest about what each mechanism can do:

- `--label Y` asks the app to bring that element into view (`AXScrollToVisible`),
  confirmed by the element's frame moving. Works on Chromium web content. For content
  genuinely **off-screen** do not expect it: SwiftUI accepts and does nothing, AppKit
  list rows refuse (measured on both).
- `--to 0..1` writes the vertical scroll bar where one exists, found by attribute or, for
  the overlay scrollers modern AppKit hides, by role walk. Safari's web content exposes
  a writable bar; Chromium and Electron never do.
- `--dy N [--dx N]` posts wheel events, which every toolkit measured ignores. A bare
  `--dy` usually earns an honest `noEffect`; positive `dy` means "reveal content below".
- `--until-text S [--dy ±1]` is the deterministic form for content the tree does not
  expose: each step captures the target's window, OCRs it locally, and stops the moment
  the string is legible. The stepper is the scroll bar, sized from its thumb with overlap
  so a screenful can never skip the target; `--dy`'s sign is the direction. Twelve steps
  per call, then `callAgain: true` with document left. The reply's `foundAt` rect is
  ready for `click --x --y` at its center. Two identical frames end the loop honestly:
  the end of the content, or a toolkit ignoring the mechanism (the referral says which
  channel can reach it). Needs Screen Recording.

**`statusitem --app X [--label Y] [--press]`** — lists an app's menu bar status items
(`items[] = {role, label, frame}`), or presses one by `AXPress`, cursor-free. Status
items live in a separate extras bar no window walk reaches, so this is the only ghost
path to a MenuBarExtra. Evidence is the target's window count, because the press call
itself can block in menu tracking and return an error for a press that fully worked.
System Settings caveat: the opened menu belongs to the pane's appex, so the count can
miss it and the verdict stays `unverifiable` for a menu that visibly opened; verify with
a region screenshot. Such a menu is not dismissible by any ghost mechanism; choose an
item, quit the host, or use a session-level Escape when the hardware gates are passed.

**`launch --app X [--confirm]`** — starts an app without taking focus and returns once its
accessibility tree answers: `ready: true` means "you can drive it now", not "the process
started" (20 s budget; 5 s when it was already running, reported `alreadyRunning`).
Takes a name, a bundle id, or a full path. Refused while the frontmost app is fullscreen
unless `--confirm`: a new window arriving switches Spaces and throws the human out of
their game. `park` the target instead.

**`activate --app X [--confirm]`** — brings an app forward on purpose, the one thing
ghost verbs promise never to do, so it is presence-gated like hardware input. Read-back
says whether it landed: macOS sometimes declines to promote an accessory (menu-bar,
LSUIElement) app while a regular app holds focus, and the reply says so rather than
claiming success. Use it when background delivery is not dependable: AppKit menus,
WebKit hover.

## 6. When the tree is empty: vision

About a sixth of popular macOS apps expose no usable accessibility tree. Rocuronium's
answer has three tiers, tried only when the previous one fails.

1. **Accessibility** — everything above. Free, exact, works behind a lock.
2. **Detector + OCR** — when `click --label` or `type --label` finds nothing in the tree,
   the engine captures the target's window and looks for the label as legible text; a
   hit becomes coordinates, delivered through the normal tentacles by hit-test, and the
   reply says `groundedBy: "detector"`. Needs Screen Recording. A YOLO detector for
   icon-shaped controls is being trained; until it ships, this tier is OCR only.
3. **Local VLM** — when OCR cannot match (icon-only targets, loose phrasing), a local
   grounding model (Holo 3.1 4B via MLX) turns the instruction plus the window into a
   point, `groundedBy: "vlm"`. Loaded on first use, evicted after five idle minutes.
   The model is a download from the Settings window (⌘, in the popover), never bundled;
   without it the tier is skipped.

Vision-grounded coordinates are less certain than tree-resolved ones: the `groundedBy`
field is your cue to verify with a `screenshot --since` or a `read --since`. When all
three fail, the error names it: "'Send' (AX tree empty, vision grounding found nothing)".

For your own eyes there is `screenshot` (§4), and for text the tree does not carry,
`scroll --until-text` (§5). There is no verb yet that returns OCR'd text with rectangles
directly; that is on the plan.

## 7. Cursor paths: move and drag

`move` glides the **real** cursor along a path and leaves it on the destination; `drag`
does the same with a button held (down at `--from`, up at `--to`). There is no ghost
variant and there will not be one: per-pid posted motion is dropped wholesale by the
window server (tracking areas, SwiftUI `onHover`, WebKit hover, content and title-bar
drags all stayed silent, background and frontmost alike). So both take the physical
cursor and are presence-gated like `activate`: refused while a human is present unless
`--confirm`, refused while the screen is locked, refused when another app's window
covers the action point and `--app` was given.

    move  (--to x,y | --app X --label Y [--role R]) [--from x,y] [--via "x,y x,y…"]
          [--duration s] [--dwell ms] [--easing linear|ease-in|ease-out|ease-in-out]
          [--restore] [--confirm]
    drag  --from x,y --to x,y [--via …] [--button left|right] [--app X] [--duration s]
          [--dwell ms] [--easing e] [--restore] [--confirm]

**Hover is `move`.** The destination can be an element (`--app X --label Y`); the cursor
stays there unless `--restore`, because a hover only means something while it lasts. A
bare start→end `move` follows a slightly bowed arc, because human motion is never a
ruler line; `drag` paths stay exact (sliders, selections), and `--via` waypoints are
honored as given, so a nav-tab-then-flyout chain is one curve that never leaves the
hover region. `--duration` is 0.05–10 s; the default is distance-based with ease-in-out,
which is what velocity-watching UI expects.

**Evidence.** The cursor's actual end position is read back (`confirmed` means the
pointer provably stands on `plannedEnd`), and with `--app` the target's window count
before/after is reported: a flyout or tooltip window appearing is a window appearing.
And with `--app`, what the hover *revealed* is now read for you: the window's tree is
diffed across the gesture and reported as `treeChanges`/`treeDelta` — the tooltip that
appeared, the controls that unhid. `--dwell <ms>` holds at the destination before the
read, for a tooltip that takes its time (AppKit shows them after ~1 s). Leave `--restore`
off when you want the reveal: a restored cursor has already left by the time the tree is
read, so the reveal collapses. Item 3's `help` field carries many tooltips without a
hover at all — try `find` first.

**Measured caveats, all reported in replies.** Hover lands on whatever window is topmost
at the point. WebKit/WKWebView pages ignore all motion while their app is inactive, so
`activate` before web hover. With `--app` given and the target not frontmost, **both
verbs activate it first** (a focus change, reported as such), and `drag` also posts a
click at the start point to absorb the activating click, as one atomic sequence inside
the daemon. A brushed mouse is absorbed (the glide bends and eases
back on path); about a quarter second of deliberate motion makes the gesture yield: the
button is released, the reply says "yielded to the hand on the mouse". A drag aborted
mid-path releases its button where it stopped, never leaving it held.

## 8. Sequence plans

`plan` executes a list of steps as one daemon-side operation, no round-trips between
steps, so the world cannot change between them. Each step is an existing verb with its
arguments plus an optional `expect` guard and an `onFail` policy.

    rocuronium plan --file steps.json      (or pipe JSON to stdin)
    { "profile": "ghost", "steps": [
      { "command": "click", "app": "TextEdit", "label": "Save",
        "expect": { "type": "window-vanishes", "title": "Save" }, "onFail": "abort" },
      { "command": "type", "app": "TextEdit", "text": "done",
        "expect": { "type": "readback-contains", "text": "done" } } ] }

| guard `type` | passes when |
|---|---|
| `verdict` | the step's verdict equals `verdict` |
| `readback-contains` | the step's read-back contains `text` |
| `window-appears` / `window-vanishes` | a window matching `title` exists / is gone |
| `text-visible` / `text-vanishes` | an element matching `label` is in / gone from the tree |
| `quiet` | the window's tree holds still for `ms` (default 600) — the view settled |
| `token-changed` | the window's tree differs from the walk observation `token` recorded |

`onFail`: `abort` (default; returns the transcript so far), `continue`, `pause-for-human`
(halts as if ⌃⌥⇧⎋ were pressed and waits for the popover's resume), or
`{"fallback": {step}}` (one alternative step, one level deep). Profiles: `ghost`
(default) forces hardware input off per step, no overlay, no pacing; `visible` narrates
each step in the bezel with 500 ms between steps. The reply is one transcript: per-step
`verdict`, `guardPassed`, `guardReason`, `policy`, fallback outcome. ⌃⌥⇧⎋ aborts mid-plan.
Steps cannot yet consume an earlier step's reply (a `foundAt` feeding a click).

## 9. Presence: who else is at this Mac

Every reply carries `presence.state`: `present`, `idle`, `away`, or `unknown`, read from
HID idle time, lock state, and display power. **Unknown is treated as present**, the
cautious reading. `mayTakeCursor` is true only when `away`; `advice` is one sentence on
what is acceptable right now. What gates on it:

- `activate`, `move`, `drag`, `key --allow-hardware-input`: refused unless `away` or
  `--confirm`, and refused outright while the screen is locked or the aim point is
  covered by another app's window.
- `launch`: refused while the frontmost app is fullscreen unless `--confirm`.
- Everything else is ghost-safe by construction: tentacles 0–3 never move the cursor
  and never change the frontmost app, so they are fine while a human is typing.

**The visible agent.** Cursor-taking work is visible work. Whenever a command opts into
hardware input, and always for `move`/`drag`, the app shows the presence overlay: a
whisper of tint over the desktop, an opaque bezel narrating each action in verdict
language with elapsed time (draggable; the position is remembered), and the jellyfish
escorting the cursor while a command is in flight. Before each hardware click a sigil
charges at the aim point for about 600 ms; that wind-up is a deliberate interrupt window.
The overlay lingers ~3 s after a cursor-taking action and ~15 s after ghost commands when
the "show overlay for every action" toggle is on.

**⌃⌥⇧⎋ is the emergency stop.** Ctrl+Option+Shift+Escape halts the engine mid-action: a
cursor trace aborts within one ~8 ms sample (a held drag button is released where it
stopped), typing stops between characters, walks bail out. Afterwards every acting and
perceiving verb is refused with "halted by the human (⌃⌥⇧⎋) — resume from the Rocuronium
menu bar"; `status` and `activity` still answer and report `halted: true`. **Resume is a
button in the popover and nothing else.** No socket verb can clear the halt. If your
verbs are suddenly refused with that message, stop and wait for the human; do not
retry and do not look for a workaround.

## 10. The refusal catalog

Refusals are rails, not failures. Each names the flag that permits the act; passing it is
a deliberate, legitimate choice when the situation calls for it.

| refusal | verb | flag | why it exists |
|---|---|---|---|
| control character in text | `type` | `--submit` | a newline in a composer sends the message |
| absent text | `type` | pass `""` | clearing a field is unrecoverable |
| session-ending or data-destroying menu item | `shortcut`, `menu` | `--confirm` | `cmd+shift+q` is Log Out from any app |
| a human is present | `activate`, `move`, `drag`, hardware `key` | `--confirm` | focus and cursor belong to the human |
| frontmost app is fullscreen | `launch` | `--confirm` | a new window switches Spaces |
| target occluded at the aim point | sting, `move`, `drag` | park the target | a real click hits whatever is topmost |
| screen locked | all hardware | none | keystrokes would land in the password field |
| display asleep | all perception | none | every tree collapses; wake first |
| `--timeout` over 25 | `wait` | loop on `callAgain` | the socket cancels at 30 s |
| capture path exists, is not `.png`, or is outside the permitted folders | `screenshot` | choose another path | an unchecked path is an arbitrary file overwrite |
| park destination on no display | `park` | pick a visible point | the window would be unreachable |
| ambiguous app or element | any | `--pid`, bundle id, `--role` | a coin flip on somebody's windows |

`--allow-hardware-input` on `type`, `click`, and `key` permits the sting: legitimate when
nobody is present and the ghost tentacles have demonstrably failed. The reply will say
`cursorMovedByUs: true`, and the engine still refuses if another window covers the target.

## 11. Isolation: the virtual display

The headless virtual display is the strongest isolation available: windows parked there
occupy none of the pixels a human is looking at, which satisfies both the occlusion check
and the politeness contract. It is modeled as a **lease**, never a mode.

- `display acquire [--reason R] [--minutes N]` returns a lease id (30 min by default, up
  to 1440); `display release --lease ID` sweeps parked windows home and tears the display
  down when the last holder leaves; `display status` lists leases, parked windows, and
  **strays** (windows on the virtual display nobody parked: a saved frame restored there,
  a second window of a parked app), which release warns about and sweeps to the main
  screen.
- `park --app X` moves the app's primary window there. With no lease in force it takes an
  **auto-lease** (reason recorded from the command, id in the reply) that releases itself
  when its last parked window is returned or closes. `park --app X --x N --y N` moves the
  window to an explicit visible point, and the reply's `before` block is the undo:
  parking back to it releases the auto-lease. Attaching the display is visually silent
  on the real screen, so parking needs no presence gate.
- Teardown always sweeps parked windows home first, and the daemon's startup sweeps any
  window left on no display back to the main screen.

**The park-then-hardware pattern.** The sting clicks whatever window is topmost at the
coordinate, so a hardware click on an occluded target is refused with the occluder
named. The reliable sequence when hardware input is truly needed:

    park --app X  →  act with --allow-hardware-input  →  park --app X --x --y (the before block)

## 12. Environment facts that trip agents

**Display asleep is blindness; screen locked is not.** When the display sleeps, every
app's accessibility tree collapses to the app element, and a naive tool concludes "this
app exposes nothing". Rocuronium refuses instead: perception verbs answer "I cannot see"
and acting verbs wake the display first. A locked screen with an awake display is
harmless: full trees, ghost input works, only hardware input is refused.

**The display hold.** While a session is active (any perceiving or acting command) the
app keeps the display awake, through Adrafinil's display-class hold when its CLI is
installed or a process-local assertion otherwise, releasing after a few quiet minutes;
`status.displayHold` says which. The hold stops at the lock screen on purpose. Neither
the wake nor the hold resets `HIDIdleTime`, so presence stays honest.

**Actions that close their own app.** A press that quits or restarts its app can never
verify through the app. The engine treats the process exiting as the read-back:
`confirmed`, with the exit named. An `unverifiable` press on an app still running really
is unverified; check `apps` before retrying anything quit-shaped.

**Background apps.** Ghost delivery to background apps is dependable for accessibility
writes and unicode text, best-effort for menu presses (AppKit never validates background
menus; Electron keeps items enabled and the press usually works). When the verdict
matters and the target is AppKit-in-background, `activate` it first.

**The demo stage.** `demo` opens a deterministic practice window at (720, 200), 560×720,
every control instrumented with a counter: "Tap Target" → "clicks: N", "Type Here" →
"echo: …", a switch, a slider, a hover pad that counts even in the background, a
120-row scroll list whose needle is "Row 87 · the needle". Drive it with
`--app Rocuronium`. `demo reset` (default) zeroes the counters, `demo show` keeps state,
`demo hide` closes it, `demo render --path f.png [--w --h] [--reason opaque]` draws the
jellyfish for artwork.

**"could not reach Rocuronium.app".** The CLI speaks to a unix socket at
`~/Library/Application Support/glass.kagerou.rocuronium/control.sock`. If the app is
running and the connect still fails instantly, a second instance (a debug build from
Xcode) bound the same path and quit, leaving the release daemon listening on an unlinked
inode. `Scripts/install-launchagent.sh` quits it and re-registers the LaunchAgent;
`launchctl kickstart -k gui/$UID/glass.kagerou.rocuronium` restarts one launchd already
manages. The socket serializes requests and cancels each at 30 s; a walk that outlives
its caller is cancelled with it, so one slow target cannot poison the queue.
"""##
}
