# Delete candidates

Looks dead; scope or origin unverified. Kiri confirms → it goes.

Surfaced by `periphery scan` against `main` (2026-09-06), then traced by hand. Confirmed dead
code with established scope is deleted outright, not listed here (e.g. `ControlServer.stop()`).
This file is only for things that look dead but whose intent is a design call — API surface
kept deliberately, or a half-wired feature where the missing piece is the caller, not the code.
False positives (synthesized reads, retained handles, active WIP) are recorded at the bottom so
a later pass doesn't re-flag them.

## `Rocuronium/Core/Actuation/HardwareInput.swift:28` — `traceTolerance` (likely a latent bug)
- **What**: `static let traceTolerance: Duration = .milliseconds(1)`
- **Looks dead because**: declared with a detailed doc about defeating timer coalescing on the 120 Hz trace sleeps, but never referenced.
- **Not deleted because**: the doc says this constant *is* the low tolerance the trace pacing must use — its absence from the sleep call reads like the wiring, not the constant, is the mistake. A plain `Task.sleep` gets the default tolerance the doc explicitly warns about (the "cursor moves at 20 fps" symptom). Deleting it would paper over a real pacing bug.
- **To confirm**: should the trace pacing sleep pass `tolerance: traceTolerance` (wire it in — likely the fix), or does it already pace tightly another way, making the constant redundant?
- **Found**: 2026-09-06

## `Rocuronium/Core/Perception/TreeCache.swift:118` — `invalidateAll()` (likely missing wiring)
- **What**: `func invalidateAll()`
- **Looks dead because**: no in-repo caller.
- **Not deleted because**: its own doc says "Used on display power transitions, where every tree in every process changes shape at once." That describes a caller that does not exist — most likely a missing sleep/wake observer, i.e. absent wiring rather than dead code. Deleting it would quietly bless the gap.
- **To confirm**: should a display sleep/wake observer call this (wire it up), or is per-process `invalidate`/`evictDeadProcesses` sufficient and this can go?
- **Found**: 2026-09-06

## `Rocuronium/Core/Environment/EmergencyStop.swift:25` — `reason` (and its backing store)
- **What**: `static var reason` and, through it, the write-only `detail` mutex that `halt(reason:)` sets and `resume()` clears
- **Looks dead because**: nothing reads `reason`, so the whole `detail` plumbing is write-only. `refusalMessage` is the string every refused verb actually uses.
- **Not deleted because**: removing it changes the `halt(reason:)` API and the halt's data model — plausibly intended to surface *why* a halt happened (one caller today, ⌥⎋). A small API-shape decision, not an obvious dead branch.
- **To confirm**: surface the halt reason (in `activity`/the popover), or drop `reason`, the `detail` store, and the `reason:` parameter?
- **Found**: 2026-09-06

## `Rocuronium/Core/Environment/VirtualDisplayBridge.swift:52,178` — `Lease.expiresAt`, `releaseAll()`
- **What**: `Lease.expiresAt` (assign-only) and `func releaseAll()` (no caller)
- **Looks dead because**: expiry is enforced by a sleeping expiry Task, never by reading `expiresAt`; `releaseAll()` has zero in-repo callers. `Lease` is `Identifiable, Sendable` — no synthesized reader of `expiresAt`.
- **Not deleted because**: `expiresAt` is meaningful lease metadata (a `display status` reply could show it), and `releaseAll()` reads as intended "deliberate reset" API — likely waiting on a reset verb or menu action not yet wired. Deleting either could remove a half-built feature.
- **To confirm**: is a "reset the virtual display" command/menu planned (keep `releaseAll`), and should `display status` expose lease expiry (keep `expiresAt`)?
- **Found**: 2026-09-06

## `Rocuronium/Core/Perception/FrameStore.swift:15,26,28` — unread `Frame` fields
- **What**: `Frame.token`, `Frame.scale`, `Frame.origin`
- **Looks dead because**: assigned in `store(...)` but never read back — the `--since` diff in `CommandRouter.captureReply` reads only `key`, `pixelWidth`, `pixelHeight`, `bytes`. `Frame` is a plain struct (no Codable/Equatable reading them implicitly).
- **Not deleted because**: they are self-describing metadata of a stored capture (its token, pixels-per-point, screen origin). A future `screenshot --since` mapping a diff rectangle back to screen points would want `scale`/`origin`; removing them now ripples into the `store` signature.
- **To confirm**: is richer `--since` geometry planned, or should the stored record hold only what the current diff reads?
- **Found**: 2026-09-06

## `Rocuronium/Core/Perception/ElementQuery.swift:31` — unread `Match.path`
- **What**: `ElementQuery.Match.path`
- **Looks dead because**: every walk builds a `path` string per match, but nothing consumes it. `Match` is a plain struct.
- **Not deleted because**: it is the human-readable ancestry of a match — plausibly intended for a future `find` reply field or diagnostics. Building it is the cost; the field is the record of it.
- **To confirm**: surface the element path in a reply/diagnostic, or drop it (and the code computing it)?
- **Found**: 2026-09-06

## `Rocuronium/Core/Plan/PlanExecutor.swift:48` — `isPaused`
- **What**: `var isPaused: Bool { pauseContinuation != nil }`
- **Looks dead because**: no in-repo reader; the executor branches on the continuation directly, not this accessor.
- **Not deleted because**: a clean state accessor a `plan status` reply or a test could reasonably read; unclear whether it was added ahead of a caller.
- **To confirm**: is anything meant to read plan pause state, or can it go?
- **Found**: 2026-09-06

## `Rocuronium/App/Theme.swift:11` — unused token `idle`
- **What**: `Theme.idle` (main flags only this one; the stale-tree siblings are now all used)
- **Looks dead because**: no in-repo reference; grep confirms. Every other token in the scale is used.
- **Not deleted because**: `Theme` is documented as "the suite's shared language (Adrafinil, Phosphene): one radius/spacing scale" — a deliberately *complete* token set mirrored across the kageroumado menu-bar apps. An unused token may be there to keep the scale whole.
- **To confirm**: keep the token catalog complete to match Propofol/sibling apps, or trim to what this app renders?
- **Found**: 2026-09-06

## `Rocuronium/App/DemoStage.swift:22` — `isVisible`
- **What**: `var isVisible: Bool` on `DemoStageController`
- **Looks dead because**: no caller (the demo verb branches on `action`, not visibility).
- **Not deleted because**: a plain state accessor a socket `demo status` reply or a test could want; unclear whether it precedes a caller that hasn't landed.
- **To confirm**: is anything meant to read demo-stage visibility, or can it go?
- **Found**: 2026-09-06

---

## Confirmed false positives — do not re-flag

Periphery reports these as unused; each is actually reached, so they stay and are **not**
candidates. Recorded here so the next scan's noise is already explained.

- **`Vision/` grounding cascade** (`GroundingBackend` protocol + `MLXBackend`, `FoundationModelsBackend`, `ScreenshotBackend`, and `DetectorBackend`'s `isModelInstalled`/`identifier`/`inputSize`/`iouThreshold`/`judge`/`toVisionCoords`/`classID`; `Engine` `confidence` on `VisionRow`) — **active WIP**. The detector tier ships and is used (`detector.detect`/`locate`/`isAvailable` in `Engine.visionRows`); the VLM/screenshot tiers and the `judge` leg are under construction (VLM tier blocked — see ROADMAP). Do not delete in-flight work.
- **`TreeCache.swift:35,36,39`** `frontWindowTitle`/`frontWindowFrame`/`displayAwake` — read by the synthesized `==` of `struct Fingerprint: Equatable`; deleting changes cache-invalidation semantics.
- **`PresenceOverlayController.swift:23`** `bezelMoveObserver` — a NotificationCenter token that must be retained for the observer to stay alive.
- **`BitjellyArt.swift:138`** `drawBody(lean:)` unused parameter — a shared polymorphic signature both art branches call.
- **`RocuroniumTests.swift:4`** unused `Rocuronium` import — test-target stub.
