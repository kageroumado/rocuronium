# Isolation: the virtual display

The headless virtual display is the strongest isolation available: windows parked there occupy none of the pixels a human is looking at, which satisfies both the occlusion check and the politeness contract. It is modeled as a **lease**, never a mode.

- `display acquire [--reason R] [--minutes N]` returns a lease id (30 min by default, up to 1440); `display release --lease ID` sweeps parked windows home and tears the display down when the last holder leaves, and `display release` with no `--lease` releases every lease at once (the deliberate reset); `display status` lists leases (each with the seconds until it auto-expires), parked windows, and **strays** (windows on the virtual display nobody parked: a saved frame restored there, a second window of a parked app), which release warns about and sweeps to the main screen. A window that cannot be swept home is named in the reply as stranded, rather than silently left behind.
- `park --app X` moves the app's primary window there. With no lease in force it takes an **auto-lease** (reason recorded from the command, id in the reply) that releases itself when its last parked window is returned or closes. `park --app X --x N --y N` moves the window to an explicit visible point, and the reply's `before` block is the undo: parking back to it releases the auto-lease. Attaching the display is visually silent on the real screen, so parking needs no presence gate.
- Teardown always sweeps parked windows home first, and the daemon's startup sweeps any window left on no display back to the main screen.

**Session boundary:** creating a leased display is supported in the physical-console session. In an off-console agent session, `CGVirtualDisplay` attaches the new display to the physical console, so `display acquire` and `park` auto-creation refuse before calling it. Use the agent session's existing Screen Sharing display. Unreadable session identity also refuses creation.

## The park-then-hardware pattern

The sting clicks whatever window is topmost at the coordinate, so a hardware click on an occluded target is refused with the occluder named. The reliable sequence when hardware input is truly needed:

    park --app X  →  act with --allow-hardware-input  →  park --app X --x --y (the before block)

## Real Spaces vs the virtual display

`space` drives Mission Control Spaces — what you want for *testing* an app across Spaces, as opposed to hiding work on the virtual display.

- `space list` — the Spaces per display, each with a 1-based index, id, kind (user/fullscreen/system), and which is active. Read-only.
- `space switch (--next | --prev | --to <index>)` — moves the display to another Space. This **changes what the human sees on their real display**, so it is *not* ghost: gated like `activate` — refused while a human is present unless `--confirm`. This is exactly why the virtual display, not Space-switching, remains the answer for invisible agent work.
- `space move --app X [--window …] --to <index>` — sends a window to another Space without switching to it. Non-disruptive to the current view, so it is un-gated and just reported.

Built on the same private SkyLight/CGS footing as the virtual display; `space list` degrades to empty rather than lying if the API is mid-transition.

## The agent session: a second user with its own cursor

The virtual display hides windows; it does not give you a cursor of your own. The **agent session** does: a second macOS user (`agent` by default) logged in off-console, so the hardware tentacle there takes *that* session's cursor, which no human is watching. It is a parallel worker, not a proxy — none of the human's logins, files, or keychain exist in it.

- `session status` — the account and uid, whether a session exists and the age of its login process (including time spent at the user chooser), whether the dead-man's switch is armed, the session's displays, and whether Rocuronium inside answers with `offConsole: true`. Safe to poll; answers even while halted.
- `session stop` — ends the session (bootout of the account's GUI domain) and confirms its loginwindow is gone. During startup cancellation, JSON returns `state: stopping`; poll status until `idle` or `failed`. The plain CLI follows this transition automatically. Always allowed, halted or not.
- `session enable` / `session start` belong to the human, from the CLI: enabling asks for a one-time helper approval. Start uses the stored credential and a held loopback Screen Sharing connection to create a separate virtual session. JSON returns `starting`; poll until `running` or `failed`. A start during `stopping` is refused until cleanup finishes. Over MCP, `session` takes `status` and `stop` only.

What to know before relying on one:
- **The watcher ends the session.** A manually started session needs `session watch` armed explicitly inside the agent account. Once armed, it ends the session when the console daemon stops sending heartbeats (15 s), when that daemon quits or crashes, or when it receives an explicit `stop` line. Automatic starts arm and own the watcher before reporting `running`. Live trials verified heartbeat survival, EOF cleanup, explicit stop, and timeout cleanup; a live console-daemon crash also removed the running agent session. The console emergency shortcut stays registered through agent startup, work, and shutdown, including when the overlay hides; its physical trial remains pending. A session you were driving can vanish; `session status` says why in the activity log.
- **Inside it, `offConsole` is true** and presence reads `away`: the presence gates relax and hardware events post at the session tap, which is what keeps them off the human's screen. Never trust a daemon reporting `offConsole: false` to be the agent session.
- **Accessibility is granted once, by a human, inside the session.** Until then `status` there shows `trusted: false` and every posted event is silently dropped — reads work, acts do not.
- **Start one per task, stop it when done.** An idle session costs ~2.4 W that cannot be reduced (SIP protects the daemons that spend it); a fresh one takes seconds.
