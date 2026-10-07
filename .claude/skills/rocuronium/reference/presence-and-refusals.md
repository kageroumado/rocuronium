# Presence and the refusal catalog

## Who else is at this Mac

Every reply carries `presence.state`: `present`, `idle`, `away`, or `unknown`, read from HID idle time, lock state, and display power. **Unknown is treated as present**, the cautious reading. `mayTakeCursor` is true only when `away`; `advice` is one sentence on what is acceptable right now. What gates on it:

- `activate`, `move`, `drag`, `key --allow-hardware-input`, `click --foreground`: refused unless `away` or `--confirm`, and refused outright while the screen is locked or the aim point is covered by another app's window.
- `launch`, `activate`, `move`, `drag`, `click --foreground`: refused while the frontmost app is fullscreen unless `--confirm` — bringing another app forward (or taking the cursor over the game) switches Spaces and throws the human out of it.
- `window` (fullscreen/minimize/zoom) and `space switch`: put to the human while one is present, unless `--confirm`.
- `resize` (and its move, `--x --y`): ghost work — no cursor, no focus — so it asks nobody; refused only when the target is the frontmost app and it is fullscreen, unless `--confirm`.
- Everything else is ghost-safe by construction: tentacles 0–3 never move the cursor and never change the frontmost app, so they are fine while a human is typing.

**The visible agent.** Cursor-taking work is visible work. Whenever a command opts into hardware input, and always for `move`/`drag`, the app shows the presence overlay: a whisper of tint over the desktop, an opaque bezel narrating each action in verdict language with elapsed time (draggable; the position is remembered), and the jellyfish escorting the cursor while a command is in flight. Before each hardware click a sigil charges at the aim point for about 600 ms; that wind-up is a deliberate interrupt window. The overlay lingers ~3 s after a cursor-taking action and ~15 s after ghost commands when the "show overlay for every action" toggle is on.

**`busy` holds the panel up across a chain and tells the human what it is for.** The per-command linger fades the panel during the gaps a chain has anyway — a think between tool calls, a wait on a result, work in another tool the daemon never sees — so "gone" cannot yet mean "safe". Bracket the work instead:

| call | what the human sees |
|---|---|
| `busy on --goal "<goal>" [--steps "a\|b\|c"]` | the goal as the headline; with steps, "Step 1 of 3". `--note` is an alias for `--goal`. ≤120 chars, ≤20 steps of ≤80 chars; steps may also be a JSON array over MCP |
| `busy step [next\|<n>]` | the step pointer moves (n is 1-based; refused outside the declared range) |
| `busy wait --for "<what>" [--seconds <n>]` | a waiting state with the expected duration (0–3600 s); the next acting command ends it |
| `busy off [--result "<text>"]` | the result line, then the panel goes |
| `--why "<purpose>"` on any acting verb | that action's purpose under the headline, when no steps are declared (≤120 chars) |

Each acting command renews the hold, and the panel vanishes only when you release it, so the person can stop guarding the mouse the moment it is gone. It self-releases after ~90 s of silence, so a crash never strands it. Visual only — it changes nothing the engine does.

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
