# Presence and the refusal catalog

## Who else is at this Mac

Every reply carries `presence.state`: `present`, `idle`, `away`, or `unknown`, read from HID idle time, lock state, and display power. **Unknown is treated as present**, the cautious reading. `mayTakeCursor` is true only when `away`; `advice` is one sentence on what is acceptable right now. What gates on it:

- `activate`, `move`, `drag`, `key --allow-hardware-input`, `click --foreground`: refused unless `away` or `--confirm`, and refused outright while the screen is locked or the aim point is covered by another app's window.
- `launch`, `activate`, `move`, `drag`, `click --foreground`: refused while the frontmost app is fullscreen unless `--confirm` — bringing another app forward (or taking the cursor over the game) switches Spaces and throws the human out of it.
- `window` (fullscreen/minimize/zoom) and `space switch`: put to the human while one is present, unless `--confirm`.
- `resize` (and its move, `--x --y`): ghost work — no cursor, no focus — so it asks nobody; refused only when the target is the frontmost app and it is fullscreen, unless `--confirm`.
- Everything else is ghost-safe by construction: tentacles 0–3 never move the cursor and never change the frontmost app, so they are fine while a human is typing.

**The visible agent.** Cursor-taking work is visible work. Whenever a command opts into hardware input, and always for `move`/`drag`, the app shows the presence panel — and for ghost commands too when the "show overlay for every action" toggle is on or a session is already up. The panel is a draggable glass bar (its position is remembered per display) with two lines. Line 1: the goal (`busy on --goal`, else your latest `--why`, else "Working in <app>") and one pill holding the mode and a clock. Line 2: `2/4 ·` when steps were declared, then the action as it happens ("Typing into “Email”…"), replaced in place by its outcome ("Typed into “Email” · ✓ reads kiri@example.com", "Clicked “Sign In” · ✗ nothing changed", "◐ Not counted — you clicked in Safari during the check"), and the stop chord at the right. ✓ appears only where a result was observed. Typed text is never shown.

The pill's modes: **Background** (blue; ghost work, keep using the Mac), **Hands off** (amber; a hardware action runs — amber edge, a thin amber screen border, the jellyfish escorting the pointer, a ring that charges ~600 ms at the aim point as an interrupt window), **Needs you** (orange; a consent question, asked once inside the panel), **Thinking** (violet; nothing in flight and no end declared — the clock counts the pause), **Stopped** (red; the human's input stopped a hands-off action — "You moved the mouse — the click didn't happen" — held until your next command), **Done** (green). The full-screen layer exists only during hands-off actions and click pings, never while idle.

**Ending a session is yours to declare.** After any action without an end signal the panel reads Thinking — it never guesses you are finished. It ends with:

| call | what the human sees |
|---|---|
| `--done` on the last acting command (or `wait`) | that action's outcome, then Done, then the panel fades |
| `busy off [--result "<text>"]` | Done with the result line (or the last outcome) for 2 s, then the panel fades |
| the end of a `plan` | Done when every step ran; Ended with the reason when it stopped |
| ~60 s / ~90 s of silence after `busy on`; ~20 s without one | "No word from the agent for 1:00" / "Ended — the agent went quiet", then gone |

And it is shaped with:

| call | what the human sees |
|---|---|
| `busy on --goal "<goal>" [--steps "a\|b\|c"]` | the goal as the headline; with steps, `1/3 ·` on line 2 and numbered dots in the list. `--note` is an alias for `--goal`. ≤120 chars, ≤20 steps of ≤80 chars; steps may also be a JSON array over MCP |
| `busy step [next\|<n>]` | the step pointer moves (n is 1-based; refused outside the declared range) |
| `busy wait --for "<what>" [--seconds <n>]` | nothing: the panel releases the screen while you wait on something that isn't UI (a build, an API call); your next action or step brings it back |
| `wait --label "<what>"` | a wait on the UI, narrated: "Waiting for “Dashboard” to appear · up to 0:25" |
| `--why "<purpose>"` on any acting verb | the headline when no goal was declared (≤120 chars) |

Batch a sequence you already know as one `plan` rather than separate calls: the panel shows its steps and runs them with no Thinking between. Visual only — none of this changes what the engine does.

**Human input during an action.** Every event the engine synthesizes carries a mark, and while an acting command runs a listen-only tap watches for input without it — the human's. Kinds and timing are recorded, never key content, and the tap exists only for the duration of the action.
- **Hardware input**: from the charge-up on, any human click, key, scroll, or pointer motion beyond a few points stops the remaining payload — a click is withheld, typing stops between characters, a cursor path aborts with its button released. The reply says `humanInput.stopped: true`. Wait for the human to finish; do not re-send.
- **Ghost input**: nothing stops, since the human is using their own Mac. But a click, key, or scroll that lands in the *target* app while the action runs or its evidence is read makes a `confirmed` verdict `attribution: mixed` — the change may be theirs. Verify the specific value before trusting it.
- `humanInput.monitored: false` means the tap could not be created (no permission); no attribution is claimed then.

**⌃⌥⇧⎢ is the emergency stop.** Ctrl+Option+Shift+Escape halts the engine mid-action: a cursor trace aborts within one ~8 ms sample (a held drag button is released where it stopped), typing stops between characters, walks bail out. Afterwards every acting and perceiving verb is refused with "halted by the human (⌃⌥⇧⎢) — resume from the Rocuronium menu bar"; `status` and `activity` still answer and report `halted: true`. **Resume is a button in the popover and nothing else.** No socket verb can clear the halt. If your verbs are suddenly refused with that message, stop and wait for the human; do not retry and do not look for a workaround.

## The refusal catalog

Refusals are rails, not failures. Each names the flag that permits the act; passing it is a deliberate, legitimate choice when the situation calls for it.

| refusal | verb | flag | why it exists |
|---|---|---|---|
| control character in text | `type` | `--submit` | a newline in a composer sends the message |
| absent text | `type` | pass `""` | clearing a field is unrecoverable |
| session-ending or data-destroying menu item | `shortcut`, `menu`, a `key` chord that item carries | `--confirm` | `cmd+shift+q` is Log Out from any app |
| a human is present | `activate`, `move`, `drag`, hardware `key` | `--confirm` | focus and cursor belong to the human |
| frontmost app is fullscreen | `launch`, `activate`, `move`, `drag` | `--confirm` | bringing another app forward switches Spaces, dropping the human out of the game |
| resizing the frontmost fullscreen app | `resize` | `--confirm` | its window would leave its fullscreen Space |
| point outside the `--window` named | `click`, `type` with `--x --y` | re-read, name the window that shows the content | the tab or document changed under the caller — right app, wrong content |
| target occluded at the aim point | sting, `move`, `drag` | park the target | a real click hits whatever is topmost |
| screen locked | all hardware | none | keystrokes would land in the password field |
| display asleep | all perception | none | every tree collapses; wake first |
| `--timeout` over 25 | `wait` | loop on `callAgain` | the socket cancels at 30 s |
| capture path exists, is not `.png`, or is outside the permitted folders | `screenshot` | choose another path | an unchecked path is an arbitrary file overwrite |
| park destination on no display | `park` | pick a visible point | the window would be unreachable |
| ambiguous app or element | any | `--pid`, bundle id, `--role`, `--exact` | a coin flip on somebody's windows (several instances: the frontmost, or the only one with a window, is taken first; one whole-string label match among several is taken first) |

`--allow-hardware-input` on `type`, `click`, and `key` permits the sting: legitimate when nobody is present and the ghost tentacles have demonstrably failed. The reply will say `cursorMovedByUs: true`, and the engine still refuses if another window covers the target — tested at the aim point against every visible window stacked above the target's own window there, on any layer (menus, banners, dialogs, the menu bar); a point where the target has no window is refused if anything else is there.
