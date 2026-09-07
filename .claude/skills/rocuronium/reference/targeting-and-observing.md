# Targeting and observing

## Coordinates

One frame everywhere: **points** in the global display space, origin at the **top-left of the main display**, x to the right, y downward. A display to the right of the main one starts at x = main width; a display above it has negative y. `find` and `windows` frames, `--x --y`, `--from --to --via`, `foundAt`, `screenshot`'s `rect` and `regions[].rect`, the demo stage at (720, 200): all the same frame. The only pixels are a PNG's `width` and `height`, which are 2× the point size on a Retina display. A rect block is always `{x, y, w, h}`.

## Targeting

**Which app.** `--app` takes a localized name or a bundle id; bundle ids match exactly and win. Two running apps with the same name (a debug and a release build) are refused with both listed: pass the bundle id. Two instances of one bundle id (`open -n`) have exactly one address, `--pid`, which every app-taking verb accepts and which overrides `--app`.

**Which element.** Three locators, and no verb falls back from one to another, so you always know which mechanism answered:

- `--label <text>` — case-insensitive substring match, in one walk of the app's windows. Matching consults title, description, placeholder, then role description, then (as the last tier, only when no label matched) the element's value, so text you saw in `read` output is findable even when it exists only as a value. **What comes back is split from what is matched**: a row's `label` is the element's own name only (title / description / placeholder) and is empty when it has none, with `roleDescription` ("button"), `help` (the tooltip, `AXHelp` — an icon button's name without a hover), `identifier` (`AXIdentifier`, SwiftUI's `accessibilityIdentifier`, often the symbol name), `subrole`, and `near` (the nearest labelled sibling and the bearing to it, "right of 'Undo'") in their own fields. So an **icon-only button is `label:""`, `roleDescription:"button"`** — match on its help, identifier, or near, or list `find --role button` and aim by frame.
- `--role <r>` narrows a label match when several roles share the text (a button and a menu item both named "Restart"). `button` and `AXButton` both work.
- `--x <n> --y <n>` hit-tests the point. For a press, a hit on a plain group ascends to the enclosing pressable control (SwiftUI wraps buttons this way).
- Neither given: the app's **focused element**. That is where `type` goes by default.
- `--window <title substring>` scopes the verb to one of the app's windows instead of its primary one — the answer to two "Untitled" windows, a sheet, or a second document. It works on `find`, `read`, `click`, `type`, `wait`, `screenshot`, `move`, `drag`, `park`, and `resize`; ambiguity is refused with each candidate's index and frame listed, and a `screenshot` that cannot be scoped to the named window refuses rather than widening to the display.

**Ambiguity is refused, never guessed.** A label matching several elements returns the candidates with their roles; the next move is `--role`, a longer label, or coordinates. Substring matching means `delete` can name three buttons, and acting on whichever sorted first is a coin flip on somebody's data.

**Same-titled windows.** When two windows share a title (`--window Untitled` matching both), the refusal lists each with a **0-based index** and its frame — the same order `windows --app` prints, echoed as `windowCandidates` in the reply. Pick one with `--window-index <n>` (0 is the first), or `--window-at <x,y>` to pick whichever window contains a screen point. Both refinements narrow the title match — or the whole window list when `--window` is omitted, so `--window-at` alone means "whichever window is under this point". They work everywhere `--window` does.

**Menu items never match label queries.** `find`, `click`, `type`, `scroll`, `wait`, and `read --label` skip the menu bar; a closed menu item's frame is a meaningless 0×0 rect at the screen corner, and matching one turned "wait for the page to load" into a hit on a History-menu entry. Menus belong to `menu` and `shortcut`, which resolve them properly.

**Window scope.** Without `--window` a verb acts on the app's primary window (and `read --label` on one element's subtree). `--window <title substring>` picks a different one; `windows --app` lists the titles to choose from.

## Observing

**`status`** — `trusted` (Accessibility granted), `presence`, `idleSeconds`, `screenLocked`, `displayAsleep`, `canSee`, `mayTakeCursor`, `advice`, `halted`, `virtualDisplayActive`, `displayHold` (`adrafinil` · `internal` · `none`). Cheap, and it never pins the display awake, so a monitoring loop may poll it.

**`diag`** — what each permission check actually returns and what a real 16×16 capture attempt does. Run it before guessing at TCC state. **`request-capture`** fires the Screen Recording prompt; after a decline it returns instantly forever until `tccutil reset ScreenCapture glass.kagerou.rocuronium`.

**`apps`** — the running apps a human would see in the Dock: `name`, `bundleID`, `pid`, `frontmost`, `hidden`, `launchedAt`, and `bundlePath`. The last two tell two instances of one bundle id apart: pick the pid by start time or path rather than guessing, since guessing killed the wrong app once. The same detail is in the ambiguous-app refusal.

**`windows --app X`** — `title`, `frame`, `minimized`, `main`, `display`, `onVirtualDisplay`, `stray` (on the virtual display, parked by nobody), and `onAnyDisplay: false` for a window stranded where no display reaches.

**`find --app X [--label Y] [--role R] [--all] [--limit N] [--offset N] [--ocr]`** — a page of matches (default **20**), each `{role, label, value, depth, frame}`, plus `shown`, `total`, `offset`, `elementsVisited`, and `truncated`/`truncationReason`. With only `--role`, every element of that role; with neither, every editable field; with `--all`, **every element that carries a frame** ("show me everything you can see"), which `--role` still narrows. `--limit`/`--offset` page the result, and the reply's `shown`/`total` make the cap explicit instead of silent. The walk is bounded (60 000 elements, 18 s wall clock) and truncation is reported with its reason: "nothing found" and "stopped looking" are different answers. When the walk finds nothing and Screen Recording is granted, `find` **falls back to OCR** automatically; `--ocr` forces it. Vision rows are `{role: OCRText, label: <text>, frame, groundedBy: ocr}` with `shown`/`total` — text with screen-point frames for a window whose tree is empty or lying. When the **UI Detector** model is installed (reference/vision.md), the vision path also returns control boxes as `{role: UIElement, label, frame, groundedBy: detector, confidence}` — each box labeled from the text inside it, so an **icon-only control comes back with an empty label and a real frame**, addressable by coordinate. Each row's `groundedBy` distinguishes a text sighting from a proposed control.

    find --app Finder --role button
    AXButton  (button)  @(1448,474)  help 'Back'  near left of 'Path'  depth 7
    AXButton  (button)  @(1448,698)  near right of 'Back'  depth 7
    …
    5 shown · 994 elements visited

**`read --app X [--label Y] [--role R] [--since T] [--ocr]`** — the app's text through accessibility: static text, field values, button titles, checked states, indented by depth, with every interactive element's role shown so you know it can be acted on. Orders of magnitude cheaper than a screenshot, and it works behind a locked screen. Budgets: 20 000 elements, 30 000 characters, 4 000 per value, depth 40, 18 s; the reply carries `truncationReason` when one bit. A web area that yields no text is reported as **hidden, not blank**, with a referral to the channel that can read the DOM. When the whole-window walk finds no text and Screen Recording is granted, `read` **falls back to OCR** automatically; `--ocr` forces it. Vision rows come back as `{role: OCRText, value: <text>, frame}` in reading order (scope `window (OCR)`, `groundedBy: ocr`), with no token or delta — there is no tree walk to diff. When the **UI Detector** model is installed, control boxes join the text as `{role: UIElement, value, frame, groundedBy: detector, confidence}` (scope `window (vision)`), so an icon toolbar reads as addressable controls rather than blank space.

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

**Pay for the change, not the frame.** Pass the token back as `--since` and the reply is the structural delta: elements appeared (grouped under their topmost appeared ancestor, "appeared: AXPopover 'Save options' containing [AXButton 'Cancel', AXButton 'Save']"), elements vanished, and values old → new. The daemon keeps a few recent observations per target; a token that cannot be diffed honestly (evicted, another process, a different window or scope, a truncated walk, wholesale change) **degrades to the full reply with `diffNote` naming why**, never to a silently wrong diff.

    read --app Rocuronium --since ax95119-3d1a92d3
    value changed: AXStaticText: 'clicks: 0' → 'clicks: 1'
    1 change(s) in window 'Rocuronium Demo Stage' since ax95119-3d1a92d3
    token ax95119-e5f74fff

**`wait --app X (--label Y [--role R] [--gone] | --for '<guard json>') [--timeout S]`** — blocks until a condition holds. `--label` (with `--gone` for disappearance) is the sugar form; `--for` takes the same guard object a `plan` step's `expect` uses (reference/plans.md), which adds `window-appears`/`window-vanishes` (by title), `text-visible`/`text-vanishes`, and two guards written for waiting: `{"type":"quiet","ms":800}` blocks until the window's tree holds still for that long — how "the view finished loading" is actually detected, since there is no done event — and `{"type":"token-changed","token":"ax…"}` blocks until the tree differs from a prior whole-window `read` token ("wait until anything changes"). Default 10 s, at most 25 because the socket cancels requests at 30: a timed-out reply says `callAgain: true`, so loop rather than asking for a longer block. `ok` mirrors `satisfied`. The right primitive after `launch`, after a click that opens a dialog, before reading a slow view.

**`screenshot [--app X | --x --y --w --h] [--path F] [--since T]`** — hands the pixels to you; your model does the looking. `--app` captures the app's primary window through a window filter (occlusion-proof, works while parked), a region captures visible pixels, and with neither the main display is captured. A window **parked on the virtual display** is captured by a raw region grab at its parked frame (the reply carries `parked: true`). Reply: `path`, `width`/`height` (pixels), `rect` (points), `token`, `window`. Captures land in the app's `captures` folder and are swept after 24 h; `--path` must end in `.png`, must not exist, and must be under Desktop, Downloads, Pictures, `/tmp`, or that folder. With `--since` the reply is changed-region crops (`regions[] = {rect, path}`, `changedFraction`), or "content scrolled ~N pt" with an edge-strip crop of what was revealed, or `changed: false`; a wholesale change returns the full frame with a `diffNote`. `--since` and `--path` are mutually exclusive. Needs Screen Recording; refused while the display sleeps, because that frame would be black.

**`activity`** — the last 50 acting commands with verdicts, the same record the human sees in the menu bar popover, plus `halted`. How a session re-orients after a context reset: both sides of the table are reading one log.
