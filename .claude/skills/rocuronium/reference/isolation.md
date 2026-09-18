# Isolation: the virtual display

The headless virtual display is the strongest isolation available: windows parked there occupy none of the pixels a human is looking at, which satisfies both the occlusion check and the politeness contract. It is modeled as a **lease**, never a mode.

- `display acquire [--reason R] [--minutes N]` returns a lease id (30 min by default, up to 1440); `display release --lease ID` sweeps parked windows home and tears the display down when the last holder leaves, and `display release` with no `--lease` releases every lease at once (the deliberate reset); `display status` lists leases (each with the seconds until it auto-expires), parked windows, and **strays** (windows on the virtual display nobody parked: a saved frame restored there, a second window of a parked app), which release warns about and sweeps to the main screen. A window that cannot be swept home is named in the reply as stranded, rather than silently left behind.
- `park --app X` moves the app's primary window there. With no lease in force it takes an **auto-lease** (reason recorded from the command, id in the reply) that releases itself when its last parked window is returned or closes. `park --app X --x N --y N` moves the window to an explicit visible point, and the reply's `before` block is the undo: parking back to it releases the auto-lease. Attaching the display is visually silent on the real screen, so parking needs no presence gate.
- Teardown always sweeps parked windows home first, and the daemon's startup sweeps any window left on no display back to the main screen.

## The park-then-hardware pattern

The sting clicks whatever window is topmost at the coordinate, so a hardware click on an occluded target is refused with the occluder named. The reliable sequence when hardware input is truly needed:

    park --app X  →  act with --allow-hardware-input  →  park --app X --x --y (the before block)

## Real Spaces vs the virtual display

`space` drives Mission Control Spaces — what you want for *testing* an app across Spaces, as opposed to hiding work on the virtual display.

- `space list` — the Spaces per display, each with a 1-based index, id, kind (user/fullscreen/system), and which is active. Read-only.
- `space switch (--next | --prev | --to <index>)` — moves the display to another Space. This **changes what the human sees on their real display**, so it is *not* ghost: gated like `activate` — refused while a human is present unless `--confirm`. This is exactly why the virtual display, not Space-switching, remains the answer for invisible agent work.
- `space move --app X [--window …] --to <index>` — sends a window to another Space without switching to it. Non-disruptive to the current view, so it is un-gated and just reported.

Built on the same private SkyLight/CGS footing as the virtual display; `space list` degrades to empty rather than lying if the API is mid-transition.
