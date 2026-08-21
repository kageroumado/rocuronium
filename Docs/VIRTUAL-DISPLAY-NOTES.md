# Virtual display research — absorb, auto-lease, and popup containment

*Research notes, 2026-08-22. Sources: `~/Developer/rocuronium/ARCHITECTURE.md` §10/§9a,
`Rocuronium/Core/Environment/VirtualDisplayBridge.swift`,
`Rocuronium/Control/CommandRouter.swift` (display/park/windows verbs),
Test Display source at `~/Developer/tools/VirtualDisplay/` (note lowercase `tools/`; the
memory file says `Tools/`), memory `reference_virtual_test_display.md`,
`~/Developer/ReverseEngineering/notes/dock-display-switching.md`, macOS 26.5 SDK, web.*

Each claim is tagged: **[measured]** (executed on this machine, here or in a prior logged
session), **[documented]** (Apple docs / RE'd binary), **[community]** (consistent forum
consensus, no first-party doc), **[unverified]** (nobody has checked).

---

## Recommended plan

1. **Absorb the display into the rocuronium daemon.** The display-creating core of Test
   Display.app is ~80 lines around the private `CGVirtualDisplay` ObjC API, and the macOS 26
   SDK's `CoreGraphics.tbd` exports all four classes **[measured — grep of the SDK tbd]**, so
   it links directly with a 41-line local header. In-process creation deletes the whole
   launch/attach/ownership dance in `VirtualDisplayBridge` (launch polling, `startedByUs`,
   `NSRunningApplication` tracking): the lease refcount *is* the display's lifetime. Keep
   Test Display.app working as a user-owned display rocuronium will park onto but never
   terminate — that preserves §10's ownership rule with less code, not more.
2. **Auto-acquire on `park`, suggest-only on occlusion refusal.** `park --app X` with no
   display up takes an implicit lease (reason auto-filled from the command, id in the
   reply, visible in `display status` and the menu bar). The rung-4 occlusion refusal keeps
   *suggesting* park rather than doing it — same philosophy as presence: inform the agent,
   don't act unilaterally. Auto-release when the last parked window is returned; on expiry,
   **sweep parked windows back to their `before` positions before tearing down** — expiry
   teardown without un-park is the stranding path the code already met with a real Finder
   window **[measured — comment at CommandRouter.swift:944-948]**.
3. **Popup containment is mostly free; add a stray-window check.** The virtual display is
   never primary because we place it at x=2560 and the menu bar stays at (0,0) — banners,
   Notification Center, and (very likely) TCC prompts stay on the main display. The real
   exposures are (a) rung-4 hardware clicks near the virtual display's bottom edge can
   summon the Dock there **[documented — Dock RE]**, and (b) app-modal dialogs of parked
   apps appear on the virtual display, where only the agent sees them. Add a
   `strayOnVirtualDisplay` list to `windows`/`status`: windows whose `onVirtualDisplay`
   is true but whose id is not in the parked set. `windows` already computes
   `onVirtualDisplay` per window (CommandRouter.swift:334-336), so this is bookkeeping,
   not new perception.
4. **Before shipping any of it, run the "needs measuring" list at the bottom** — especially
   attach-flash visibility with a present user, TCC prompt placement, and whether teardown
   migrates windows back on current macOS.

---

## 1. Should the display live inside rocuronium?

### What Test Display.app actually is

Source: `~/Developer/tools/VirtualDisplay/` — `main.swift` (308 lines), bridging header
`VirtualDisplayPrivate.h` (41 lines), `build.sh`, `vdtest.m` (standalone ObjC proof).
Installed at `/Applications/Test Display.app`, bundle id `glass.kagerou.testdisplay`,
LaunchAgent autostart. **[measured — read the source]**

The 308 lines split three ways:

- **`VirtualDisplayManager` (~80 lines)** — the only part that matters. Builds a
  `CGVirtualDisplayDescriptor` (name "Claude Test Display", 3840×2160 max pixels,
  vendor/product/serial ids), creates `CGVirtualDisplay(descriptor:)`, applies
  `CGVirtualDisplaySettings` with `hiDPI = 1` and two modes → a 1920×1080 @2x screen.
  Then `CGConfigureDisplayOrigin` places it at `(mainWidth, 0)` and it sets a solid
  dark-gray wallpaper. Teardown is just releasing the ObjC object.
- **`ViewerWindowController` (~100 lines)** — optional live mirror via ScreenCaptureKit →
  `AVSampleBufferDisplayLayer`. Needs a Screen Recording grant.
- **Menu bar app scaffolding (~120 lines)** — status item, toggle menu, `.accessory` policy.

### The API

Private ObjC classes in CoreGraphics (SkyLight-backed): `CGVirtualDisplay`,
`CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`, `CGVirtualDisplayMode`. Not
DriverKit — no driver, no system extension, no approval UI, and **creating the display
needs no TCC permission at all** **[measured — Test Display has run for weeks with no
grant for the display itself; only the viewer needed Screen Recording]**.

SDK status on macOS 26.5: `CoreGraphics.tbd` exports all four class symbols (plus
`CGVirtualDisplaySettingsRefreshDeadlineNone`), so the app **links against the SDK
normally — no dlopen, no weak linking**. There is still **no public header** anywhere in
the framework **[measured — recursive grep of the SDK framework dir matched only the
tbd]**. The memory file's claim that "the macOS 26 SDK actually declares CGVirtualDisplay"
is half right: exported for linkage, not declared for compilation. The local header stays.

### Cost of absorbing into the daemon

- **Code in:** ~80 lines of creation/teardown + the 41-line header + a bridging-header (or
  ObjC shim target) addition to the Rocuronium build. The wallpaper nicety is optional
  (~30 lines). The viewer could come later for free — rocuronium already holds Screen
  Recording for `screenshot`.
- **Code out:** most of `VirtualDisplayBridge`'s hard parts — `launch()` with its 6-second
  attach poll ("launching is not attaching"), `runningApplication` lookup, `startedByUs`
  and its unconditional-clear subtlety in `teardown()`, the `notInstalled` error, the
  `isInstalled` check. In-process, "the display exists" and "we own it" are the same fact,
  and attach is observable directly (the object exists and `displayID` is nonzero) instead
  of by polling `NSScreen.screens` for a name substring — which also kills the fragile
  `localizedName.contains("Test Display")` match at VirtualDisplayBridge.swift:67 in favor
  of matching the exact `CGDirectDisplayID` we created. Net: roughly line-neutral, but
  strictly fewer failure modes and one fewer bundle to build, sign, install, and launchd-manage.
- **Signing/distribution:** private API → no Mac App Store, irrelevant — rocuronium is
  already direct-distributed with Developer ID + hardened runtime, same as Test Display
  (which proves the combination works: hardened runtime does not block calling exported
  private ObjC classes) **[measured — Test Display ships exactly this way]**.
- **Risks:**
  - *Private API drift.* Apple renamed `applySettings:` → the Swift-visible `apply(_:)`
    across SDK versions and added a refresh-deadline symbol; the shape moves. A daemon
    that fails to create a display should degrade to "isolation unavailable", not crash —
    wrap creation, treat nil as `displayNeverAttached`. **[documented — symbol diff]**
  - *Daemon crash tears down the display* (process-owned resource) with windows still on
    it. Today a Test Display crash does the same and the launchd KeepAlive restarts it,
    but the windows do not necessarily come home: this project has already measured a
    window stranded when the display went away (CommandRouter.swift:944-948). Mitigation:
    on daemon startup, sweep — any window whose frame is on no current display gets moved
    to the main screen; `windows` already flags exactly those (line 338).
  - *Lease semantics change slightly:* today `acquire` can adopt a user-started Test
    Display (and never tear it down). Keep that: if `glass.kagerou.testdisplay` is running,
    treat its screen as a user-owned parking target; otherwise create our own, named
    distinctly (e.g. "Rocuronium Display") so `windows`/logs can tell them apart.

### Verdict

Absorb. §10's ownership rule was written *because* the display was another process with
independent lifetime; in-process the rule's intent (never destroy what the user made,
never leak what we made) is enforced by construction — our display dies with the last
lease or the daemon, the user's app is never touched. The tradeoff §10 pays (launch
polling, adoption ambiguity, name matching) exists only to talk to the external app.

---

## 2. "Smart" display — auto-appear only when necessary

### Proposed policy

1. **`park --app X` auto-acquires.** No display attached → take a lease with
   `reason: "auto: park --app X"`, return the lease id in the park reply. §10 currently
   says leases are "always explicit, never a side effect of another command, so a stray
   virtual screen is traceable to a lease's recorded reason" — the load-bearing clause is
   *traceability*, not explicitness. An auto-lease that records the exact command as its
   reason, appears in `display status`, and lights the menu bar keeps the guarantee while
   dropping the two-step ceremony. (The park handler already refuses lease-less parking at
   CommandRouter.swift:948-953; auto-acquire replaces that refusal with the thing the
   error message tells the caller to do.)
2. **Occlusion refusal on rung 4 stays a suggestion.** The refusal already names the
   occluder (§9a); extend the error with a machine-readable hint
   (`"suggestion": "park --app X"`), and let the agent decide. Auto-parking here would
   move a *visible* window off-screen as a side effect of a failed click — the exact
   "presence informs the decision, it does not silently make it" line §9 draws for
   `mayTakeCursor`. Also the occluded-target case often wants the *occluder* handled, not
   the target exiled; only the agent has that context.
3. **Auto-release, two triggers.** (a) The existing lease TTL (30 min default) stays as
   the backstop. (b) New: each auto-lease tracks the window ids it parked; `park` back to
   `--x/--y` (or the window closing) decrements, and at zero the auto-lease releases
   itself. Explicit `acquire` leases are untouched — whoever asked must release.
4. **Presence gate on auto-acquire.** If presence reads `active` (human at the keyboard),
   attaching a display is a visible event (see failure modes) — return the same refusal
   `park` gives today, plus advice, unless the caller passes an explicit opt-in flag
   (mirroring `allowHardwareInput`). When `away`, auto-acquire freely.
5. **Teardown always un-parks first.** Expiry and auto-release sweep every still-parked
   window back to its recorded `before` position *before* the display goes. This closes
   the measured stranding failure and makes auto-expiry safe enough to shorten the
   auto-lease TTL (10 min, renewed by any verb that touches a parked window).

### Failure modes, enumerated

- **Attach/detach is a visible event for a present user.** Display reconfiguration can
  blank or flash connected displays briefly and triggers a global rearrangement
  notification; how visible a *virtual* attach is on this Mac (Studio Display, wired) is
  **[unverified — needs measuring; it may be a no-flash event since no real link
  retrains]**. Until measured, the presence gate above assumes the worst.
- **Arrangement reflow.** The display is added at `(mainWidth, 0)`, so existing windows'
  coordinates remain valid and nothing should move. But apps that self-position relative
  to "the rightmost screen" or re-run layout on
  `NSApplication.didChangeScreenParametersNotification` can move themselves
  **[unverified]**. Attach while the user is mid-drag of a window is a niche worse case.
- **Apps remember their screen — a real, documented risk.** AppKit frame autosave and
  state restoration store window frames in global coordinates; a saved frame at x≥2560
  will be *reapplied* on next launch. Three sub-cases:
  - Virtual display attached at relaunch → window legitimately reopens there, invisible
    to the human. Real risk; this is what the stray-window check in §3 catches.
  - Virtual display gone → `constrainFrameRect(_:to:)` pulls titled windows onto a real
    screen, but community evidence shows apps restoring to wrong screens or clamped to
    slivers when the saved screen is missing **[community — adamwulf's
    nswindow-nsscreen-restoration demo; cmux issue #2666; Apple forums thread 114255]**.
  - Mitigation for both: un-park before teardown (policy 5) writes the *original* frame
    back, so the app's own autosave records the on-screen position again before quit.
    Windows the agent launched *directly onto* the virtual display (never parked from
    the main screen) have no `before`; sweep those to a fixed main-screen point.
- **Surprise re-appearance.** With auto-acquire, a background loop that parks something at
  3 a.m. creates a display the user finds attached in the morning if teardown failed.
  The unconditional TTL plus the daemon's `releaseAll()` on termination bound this; the
  menu bar item is the honest indicator either way.
- **Two agents, one auto-lease.** Refcounted leases already handle concurrent holders
  (VirtualDisplayBridge fix noted at lines 38-42); auto-leases keyed per parked window
  inherit that.

---

## 3. Keeping system popups off the virtual display

### Where things appear (by surface)

| Surface | Placement rule | Status |
|---|---|---|
| Menu bar (primary) | The display whose top-left is (0,0) in arrangement — "main". We place the virtual display at x=2560, so main never moves. | **[documented + measured]** — `CGConfigureDisplayOrigin` in Test Display's source; arrangement observed for weeks |
| Menu bar (per-display) | With *Displays have separate Spaces* ON (default), every display gets its own (mostly inactive) menu bar, including the virtual one. Harmless — nothing appears on the real screen. | **[documented]** |
| Dock | Single process; relocates only when the **cursor** enters the bottom strip of another display (separate-Spaces OFF), or shows a per-display Dock where the cursor is (ON). No API assigns it. | **[measured — RE of Dock.app, `dock-display-switching.md`]** |
| Notification banners / Notification Center | Primary display (the menu-bar display in Arrangement). Not the "active" display. | **[community — consistent across Apple Communities, MacRumors, macmost; no first-party doc]** |
| TCC permission prompts | Posted by a system UI agent, generally center-screen on the main display in every screenshot/guide found — but no source states the rule. | **[unverified]** |
| NSAlert / app-modal dialogs | Sheets attach to their window (stay wherever the window is). Detached app-modal alerts center on the screen of the app's key window. A parked app's dialog therefore appears **on the virtual display**. | **[documented AppKit behavior; exact centering rule unverified]** |
| New windows of freshly launched apps | Restored saved frame if any (see §2), else app-chosen, typically the main/active screen. An app whose saved frame is on the virtual display reopens there. | **[community + AppKit docs]** |

### What we control

- **Keep the virtual display non-main.** Already done by construction (origin x=2560,
  `.permanently`). This is the single lever that keeps notifications, Notification
  Center, and (very likely) TCC prompts on the human's screen. Nothing to add — but the
  daemon should *assert* it: after creating the display, verify `CGMainDisplayID()` is
  unchanged, and refuse/log if some stored arrangement ever made the virtual display
  primary. Cheap paranoia, one comparison.
- **Cursor discipline is Dock discipline.** Ghost rungs never move the cursor, so the
  Dock never visits the virtual display. Rung 4 *does* move the real cursor: a hardware
  click near the virtual display's bottom edge can trigger the Dock's relocate/reveal
  path (cursor-enters-bottom-strip is the entire mechanism). Worth an inset: when rung 4
  aims at a point on the virtual display within ~10px of its bottom edge, note it —
  or simply accept it, since the Dock appearing on an invisible display costs nothing
  and reverts when the cursor returns. **[measured mechanism, consequence unverified]**
- **"Displays have separate Spaces"** changes Dock/menu-bar duplication and full-screen
  behavior, not notification placement (which follows primary either way, per community
  consensus). No reason to ask the user to change it; measure both states once.
- **NSScreen ordering cannot be "pinned" via API,** but doesn't need to be: `screens[0]`
  is defined as the zero-origin screen, which is the main display by construction. Code
  should match displays by `CGDirectDisplayID`/UUID anyway (in-process creation makes the
  id known exactly), never by array index or name.

### The reverse concern: a popup ON the virtual display, invisible to the human

Two distinct cases:

1. **A parked app's own dialog** (save sheet, error alert, update prompt) — appears on
   the virtual display with its app. This is fine *if the agent is watching*: `read` and
   `screenshot --app` both reach it. The failure is an agent that parked, finished, and
   released while the app still had a sheet up.
2. **A window nobody parked** landing there — an app restoring its saved frame onto the
   virtual display at launch, a second window of a parked app, or (worst, if it can
   happen) a system prompt.

Detection is nearly free with what exists: `windows` already computes `onVirtualDisplay`
per window from the frame center (CommandRouter.swift:333-336). Add:

- The engine records the window ids (or app+title) it parked under each lease — the
  "parked set".
- `display status` (and `windows`) gains `strays`: windows with `onVirtualDisplay == true`
  and not in the parked set. Zero cost when no display is attached.
- Teardown refuses—or warns and sweeps—when strays exist, exactly parallel to the
  existing no-display-reaches-this-window flag (line 338).
- Optionally the menu bar shows a badge when strays > 0, making the invisible visible to
  the human at a glance.

A stray check on *release* plus one on a slow timer (once a minute while leased) covers
both cases without a standing watcher.

---

## Needs measuring

1. **Virtual display attach/detach visibility on the real screen** — does creating or
   releasing a `CGVirtualDisplay` flash/blank the Studio Display, shift windows, or
   otherwise announce itself? Attach while a present user drags a window. This decides
   how strict the presence gate on auto-acquire must be.
2. **TCC prompt placement** — trigger a fresh TCC prompt (e.g. reset one:
   `tccutil reset ScreenCapture <bundle-id>` on a throwaway app) with the virtual display
   attached and an app parked there; record which screen the prompt lands on, both with
   the parked app frontmost and not.
3. **Notification banner placement with a virtual display attached** — post a
   notification (e.g. `osascript display notification`, plus one from a parked app) and
   confirm banners stay on the primary display in both separate-Spaces states.
4. **Window fate on teardown** — park a window, tear the display down *without* un-parking
   (current expiry path), and record where the window ends up on macOS 26: migrated,
   stranded off-space, or clamped. The Finder stranding was measured once; pin down the
   exact behavior and whether it differs for in-process release vs app termination.
5. **Saved-frame reopen** — park Safari (a frame-autosaving app), quit it while parked,
   relaunch with the display still attached, and confirm it reopens on the virtual
   display (the stray detector's canonical test case); repeat with the display gone to
   see the constrain behavior on this OS.
6. **Arrangement reflow on attach** — with a dozen windows across the main display,
   attach the virtual display and diff every window frame (rocuronium `windows` before
   and after) to confirm nothing moves.
7. **Rung-4 bottom-edge Dock summon** — hardware-click 5px above the virtual display's
   bottom edge (separate-Spaces OFF) and check whether the Dock relocates; confirm it
   returns when the cursor does.
8. **In-process creation itself** — a 60-line spike target in the rocuronium repo that
   creates and releases a `CGVirtualDisplay` from a daemon-shaped process (LSUIElement,
   hardened runtime, Developer ID) to confirm no entitlement or runtime surprise before
   committing to the absorption.

## Sources (web)

- [Apple Communities — notification banners on dual displays](https://discussions.apple.com/thread/6621259)
- [MacRumors — can I choose which monitor notifications show on](https://forums.macrumors.com/threads/can-i-choose-which-monitor-notifications-are-shown-on.2450144/)
- [macmost — windows across displays vs separate Spaces](https://macmost.com/macs-with-two-displays-choose-windows-across-displays-or-separate-spaces.html)
- [adamwulf/nswindow-nsscreen-restoration — origin restores, screen does not](https://github.com/adamwulf/nswindow-nsscreen-restoration)
- [cmux #2666 — window clamped to sliver after display disconnect](https://github.com/manaflow-ai/cmux/issues/2666)
- [Apple Developer Forums — restore window to correct screen](https://developer.apple.com/forums/thread/114255)
- [NSWindow.constrainFrameRect(_:to:)](https://developer.apple.com/documentation/appkit/nswindow/constrainframerect(_:to:))
