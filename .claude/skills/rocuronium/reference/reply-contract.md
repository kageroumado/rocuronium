# The reply contract

Every command answers one JSON object (`--json` prints it; MCP returns it verbatim). `ok` is the exit code: `true` exits 0. Acting verbs carry these fields:

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
| `groundedBy` | `detector` or `vlm` when the target's coordinates came from vision rather than the accessibility tree (see reference/vision.md) |
| `treeChanges` / `treeDelta` | on `click`/`shortcut`/`menu`: how many window elements moved across the act, and the rendered diff of them. Any change confirms the act on its own — the channel that sees a sibling value ticking when pixels cannot. Absent when the tree was too large to walk twice (pass `--observe`) or truncated. |

## The tentacles

In the order they are tried. Each is verified before the next is attempted; a return code alone never counts.

| # | wire name | mechanism | cursor / focus | verified by |
|---|---|---|---|---|
| 0 | `displayWake` | wake a sleeping display first | — | display awake |
| 1 | `accessibility` | `AXSetValue`, `AXPress`, `AXShowMenu` | never | read-back, window count, pixels |
| 2 | `postedEvent` | `CGEvent.postToPid` with a unicode payload | never | read-back, focus delta, pixels |
| 3 | `appAutomation` | a referral, never an adapter | never | names the channel |
| 4 | `hardwareInput` | the sting: real events on the console | **takes both** | read-back, pixels, occlusion pre-check |

## The three verdicts

- **confirmed** — something observably changed: a read-back matched what was written, a scroll bar or element frame moved, pixels changed in a window that was provably still, the target's on-screen window count moved (File ▸ New, Cancel, Escape on a dialog, a close button), an element in the window appeared, vanished, or changed value across the act (the tree-diff channel — see below), or the process exited after a quit-shaped press. Proceed.
- **noEffect** — the call reported success and nothing observable changed. This is the verdict the system exists for: WebKit's `AXSetValue` lies, background AppKit menus never validate, wheel events are ignored. Do not retry the same call harder. Change mechanism: read the referral, `activate` the target, `park` it, or verify through the tree (below).
- **unverifiable** — the target exposes nothing to read back and pixels could not testify. **Do not retry blindly**: the action may have landed, and a retry types it twice. Verify through another channel first.

## Pixels are blind to small consequences — so the tree diff is a built-in channel

Measured on the demo stage: a ghost click on "Tap Target" moves the button's own pixels back to rest and the counter that changed is one glyph in a 560×720 window, under the noise floor, so `pixelDelta` reads 0. `click`/`shortcut`/`menu` therefore walk the window's accessibility tree before and after the act and diff them: the click reports `treeChanges: 1`, `treeDelta: "value changed: AXStaticText 'clicks: 0' → 'clicks: 1'"`, and that alone confirms it. The walk is one bounded pass and is skipped on a tree too large to walk twice (Discord-sized) unless you pass `--observe`; the diff is emitted even on an already-confirmed act, because "what changed" is worth more than "something did". Confirm-only: a still tree never *refutes* a press, since the consequence can land in a popover or a second window the walk never reached. `read --since` remains the way to ask the same question by hand across any two moments.

## Two example replies, abbreviated

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

Errors are `{ "ok": false, "error": "<sentence>" }`, plus `presence` on most, `suggestion` when there is a next move, and `halted: true` after ⌃⌥⇧⎢. Refusals name the flag that would permit the act (see reference/presence-and-refusals.md).
