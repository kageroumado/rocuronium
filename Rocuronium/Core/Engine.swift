import AppKit
import ApplicationServices

/// Everything that touches accessibility, on its own executor.
///
/// **Why this type exists.** `CommandRouter` is `@MainActor`, and under SE-0461 a `nonisolated
/// async` function runs on its *caller's* executor — so the whole ladder, including synchronous
/// AX reads that can each block for the full two-second messaging timeout and a tree walk
/// measured at 1.2 s, was executing on the main thread. One unresponsive target app could hang
/// the menu bar UI. Marking the engine types `nonisolated` did not move them; only giving the
/// work its own actor does.
///
/// **Why elements never leave.** `AXUIElement` is not `Sendable` (verified against the SDK), so
/// an `AXElement` crossing an isolation boundary would be a data race the compiler is right to
/// reject. Every method here therefore accepts `Sendable` inputs — a pid, a locator, a string —
/// and returns `Sendable` output. Elements are created, used, and discarded inside.
actor Engine {
    private let cache = TreeCache()

    private enum Constants {
        /// How much a window may change on its own between two back-to-back captures and
        /// still be treated as still enough for its pixels to testify. Deliberately tight:
        /// over-trusting a moving window is what produces false confirmations.
        static let intrinsicMotionTolerance = 0.0005
        /// Fast enough that a dialog is caught promptly, slow enough that a 25 s wait on a
        /// cache-missing Electron app does not become a wall of 1.2 s walks back to back.
        static let waitPollInterval: Duration = .milliseconds(400)
        static let launchPollInterval: Duration = .milliseconds(250)
        /// Scroll areas sit near the top of any window's tree; a deep, wide search here
        /// would mean the caller mislabeled the target, not that more walking would help.
        static let scrollSearchDepth = 20
        static let scrollSearchBudget = 3000
    }

    // MARK: - Boundary types

    /// A `Sendable` snapshot of an element, since the element itself cannot cross.
    struct ElementDescriptor: Codable, Sendable {
        let role: String
        let label: String
        let value: String
        let depth: Int
        let frame: Frame?

        struct Frame: Codable, Sendable {
            let x: Double, y: Double, width: Double, height: Double
        }
    }

    /// How to find the thing to act on. Deliberately explicit: a coordinate and a label are
    /// answered by different mechanisms, and the caller should know which one replied.
    enum Locator: Sendable {
        case focused
        case named(String)
        case point(x: Double, y: Double)
    }

    struct FindOutcome: Sendable {
        let elements: [ElementDescriptor]
        let elementsVisited: Int
        let truncated: Bool
        let cacheHits: Int
        let cacheMisses: Int
    }

    /// The evidence for a window move: where it was asked to go, where it was, and where it
    /// actually landed. `setPosition`'s return code is not part of this on purpose — the
    /// window manager may clamp or refuse, and only the read-back knows.
    struct WindowMove: Sendable {
        let window: String
        let requestedX: Double
        let requestedY: Double
        let before: ElementDescriptor.Frame?
        let after: ElementDescriptor.Frame?

        /// Within a couple of points of the request. Exact equality would fail on apps that
        /// snap their own geometry, and a 2 pt snap is still "it went where we sent it".
        var landed: Bool {
            guard let after else { return false }
            return abs(after.x - requestedX) <= 2 && abs(after.y - requestedY) <= 2
        }

        var moved: Bool {
            guard let before, let after else { return false }
            return before.x != after.x || before.y != after.y
        }
    }

    enum EngineError: LocalizedError, Sendable {
        case cannotSee
        case notFound(String)
        case ambiguous(String, [String])
        case unparseableShortcut(String)
        case hazardousShortcut(String, String)
        case menuPathNotFound(component: String, available: [String])
        case menuPathIsSubmenu(path: String, items: [String])

        var errorDescription: String? {
            switch self {
            case .cannotSee:
                "The display is asleep — every accessibility tree is degenerate right now, so this would report nothing found when nothing can be seen."
            case let .notFound(what):
                "No element matched \(what)."
            case let .ambiguous(query, candidates):
                "'\(query)' matched \(candidates.count) elements: \(candidates.joined(separator: ", ")). Be more specific."
            case let .unparseableShortcut(keys):
                "Could not parse '\(keys)' — use forms like cmd+a, cmd+shift+z, cmd+left."
            case let .hazardousShortcut(path, consequence):
                "That shortcut resolves to '\(path)', which \(consequence). Pass confirm:true if that is genuinely intended. (Every app's menu bar includes the Apple menu, so session-wide items are reachable from any target.)"
            case let .menuPathNotFound(component, available):
                "No menu item '\(component)' at that level. It offers: \(available.joined(separator: ", "))."
            case let .menuPathIsSubmenu(path, items):
                "'\(path)' is a submenu, not an item — pressing it would only open it on screen. Name one of its items: \(items.joined(separator: ", "))."
            }
        }
    }

    /// Proof rather than assumption: the whole point of this actor is that its work does not
    /// execute on the main thread, and that is worth being able to check at runtime instead of
    /// inferring it from isolation annotations.
    func runsOffMainThread() -> Bool { !Thread.isMainThread }

    // MARK: - Perception

    func find(pid: pid_t, query: String?) throws -> FindOutcome {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }

        // Chromium builds its tree lazily; ask once, cheap and harmless elsewhere.
        AXElement(pid: pid).enableManualAccessibility()
        cache.evictDeadProcesses(livePIDs: livePIDs())

        let results = cache.results(for: pid, key: "find:\(query ?? "*")") {
            if let query { ElementQuery.named(query, pid: pid) } else { ElementQuery.editables(pid: pid) }
        }
        let statistics = cache.statistics
        return FindOutcome(
            elements: results.matches.prefix(20).map { descriptor(for: $0.element, depth: $0.depth) },
            elementsVisited: results.elementsVisited,
            truncated: results.truncated,
            cacheHits: statistics.hits,
            cacheMisses: statistics.misses,
        )
    }

    /// One line of a text dump, `Sendable` because `TextDump.Line` holds nothing but text.
    struct ReadLine: Codable, Sendable {
        let role: String
        let title: String
        let value: String
        let depth: Int
    }

    struct ReadOutcome: Sendable {
        /// What was read: "window 'Inbox'" or "AXTextArea 'Message'".
        let scope: String
        let lines: [ReadLine]
        let elementsVisited: Int
        let characters: Int
        let truncated: Bool
        let truncationReason: String?
        /// Set when the dump crossed a web area that exposed no text — the honest answer is
        /// "hidden, use this channel", never "the page is empty".
        let referral: Evidence.Referral?
    }

    /// Dumps the readable text of an element's subtree (by label) or the main window.
    /// The cheap way to answer "what does the app say right now" — no pixels, no model.
    func read(pid: pid_t, label: String?) throws -> ReadOutcome {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        AXElement(pid: pid).enableManualAccessibility()
        cache.evictDeadProcesses(livePIDs: livePIDs())

        let root: AXElement
        let scope: String
        if let label {
            // Same cache key as `find`, so a find-then-read pair costs one walk, not two.
            let element = try resolveNamed(pid: pid, label: label)
            root = element
            scope = "\(element.role) '\(element.label)'"
        } else {
            let application = AXElement(pid: pid)
            guard let window = application.mainWindow ?? application.windows.first else {
                throw EngineError.notFound("a window for pid \(pid)")
            }
            root = window
            scope = "window '\(window.string(kAXTitleAttribute) ?? "")'"
        }

        let dump = TextDump.dump(root: root)
        return ReadOutcome(
            scope: scope,
            lines: dump.lines.map { .init(role: $0.role, title: $0.title, value: $0.value, depth: $0.depth) },
            elementsVisited: dump.elementsVisited,
            characters: dump.characters,
            truncated: dump.truncated,
            truncationReason: dump.truncationReason,
            referral: dump.silentWebArea.flatMap { WebContent.readReferral(for: $0, pid: pid) },
        )
    }

    struct WindowDescriptor: Codable, Sendable {
        let title: String
        let frame: ElementDescriptor.Frame?
        let minimized: Bool
        let isMain: Bool
    }

    /// Every window the app exposes, with the state an agent needs before aiming anything.
    func windowList(pid: pid_t) throws -> [WindowDescriptor] {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        return AXElement(pid: pid).windows.map { window in
            WindowDescriptor(
                title: window.string(kAXTitleAttribute) ?? "",
                frame: window.frame.map {
                    .init(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height)
                },
                minimized: (window.attribute(kAXMinimizedAttribute) as? Bool) ?? false,
                isMain: (window.attribute(kAXMainAttribute) as? Bool) ?? false,
            )
        }
    }

    struct WaitOutcome: Sendable {
        let satisfied: Bool
        let elapsedSeconds: Double
        let polls: Int
        let matches: [ElementDescriptor]
    }

    /// Polls until an element appears (or, with `gone`, disappears).
    ///
    /// The timeout is the router's problem to bound: the control socket cancels requests at
    /// 30 s, so callers pass at most 25 and loop on a "call again" reply. The poll itself
    /// checks for cancellation so a cancelled request stops burning AX IPC.
    func waitFor(pid: pid_t, label: String, gone: Bool, timeout: Duration) async throws -> WaitOutcome {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        AXElement(pid: pid).enableManualAccessibility()
        let clock = ContinuousClock()
        let start = clock.now
        var polls = 0

        while true {
            polls += 1
            let matches = cache.results(for: pid, key: "find:\(label)") {
                ElementQuery.named(label, pid: pid)
            }.matches
            let satisfied = gone ? matches.isEmpty : !matches.isEmpty
            let elapsed = seconds(start.duration(to: clock.now))
            if satisfied {
                return WaitOutcome(
                    satisfied: true,
                    elapsedSeconds: elapsed,
                    polls: polls,
                    matches: matches.prefix(5).map { descriptor(for: $0.element, depth: $0.depth) },
                )
            }
            if elapsed >= seconds(timeout) || Task.isCancelled {
                return WaitOutcome(satisfied: false, elapsedSeconds: elapsed, polls: polls, matches: [])
            }
            try? await Task.sleep(for: Constants.waitPollInterval)
        }
    }

    struct Readiness: Sendable {
        let ready: Bool
        let windows: Int
        let elapsedSeconds: Double
    }

    /// Blocks until a freshly launched app can actually be driven — its accessibility tree
    /// answers — because "the process started" and "you can send it commands" are different
    /// claims, and a launch reply must mean the second one.
    func waitUntilDrivable(pid: pid_t, timeout: Duration) async -> Readiness {
        // A launch with the display asleep would never look ready: the tree stays degenerate
        // no matter how finished the app is. Wake first, same as the ladder's rung 0.
        await DisplayWake.ensureAwake()
        let clock = ContinuousClock()
        let start = clock.now

        while true {
            let application = AXElement(pid: pid)
            let windows = application.windows.count
            let finished = await MainActor.run {
                NSRunningApplication(processIdentifier: pid)?.isFinishedLaunching ?? false
            }
            let elapsed = seconds(start.duration(to: clock.now))
            // A menu bar counts as drivable even with zero windows: menu-bar apps and apps
            // that restore no windows are still fully commandable.
            if finished, windows > 0 || application.menuBar != nil {
                return Readiness(ready: true, windows: windows, elapsedSeconds: elapsed)
            }
            if elapsed >= seconds(timeout) || Task.isCancelled {
                return Readiness(ready: false, windows: windows, elapsedSeconds: elapsed)
            }
            try? await Task.sleep(for: Constants.launchPollInterval)
        }
    }

    private nonisolated func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The frame of the app's primary window, for aiming a capture at it.
    func windowFrame(pid: pid_t) throws -> ElementDescriptor.Frame {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        let application = AXElement(pid: pid)
        guard let window = application.mainWindow ?? application.windows.first,
              let frame = window.frame
        else { throw EngineError.notFound("a window with a frame for pid \(pid)") }
        return .init(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
    }

    // MARK: - Actuation

    /// Moves the app's primary window and reads its frame back as evidence.
    func moveWindow(pid: pid_t, to point: CGPoint) async throws -> WindowMove {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        let application = AXElement(pid: pid)
        guard let window = application.mainWindow ?? application.windows.first else {
            throw EngineError.notFound("a window for pid \(pid)")
        }

        let before = window.frame
        window.setPosition(point)
        var after = window.frame
        // Some apps apply geometry asynchronously; one short re-read distinguishes "slow"
        // from "refused" without turning this into a poll loop.
        if after?.origin != point {
            try? await Task.sleep(for: .milliseconds(150))
            after = window.frame
        }

        cache.invalidate(pid: pid)  // every cached frame for this process just moved
        return WindowMove(
            window: window.label,
            requestedX: point.x,
            requestedY: point.y,
            before: before.map { .init(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height) },
            after: after.map { .init(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height) },
        )
    }

    /// Delivers a keyboard shortcut by pressing the menu item that carries it, not by posting
    /// keys. Chromium ignores keycode-only posted events entirely (measured), but menus are
    /// native AppKit even in Electron — so `AXPress` on the matching item runs the same
    /// action the keystroke would, on every toolkit, without any CGEvent or focus change.
    /// No `allowHardwareInput`: a menu item is actuated by `AXPress` or not at all, so there is
    /// no rung below to permit. Accepting the flag would imply an escalation that cannot exist.
    enum ShortcutMode: Sendable {
        /// Resolve and report what *would* be pressed, without pressing. Makes the verb
        /// auditable before the fact rather than after — the reply otherwise names the menu
        /// item only once it has already run.
        case resolveOnly
        case press
        /// Press even though the item is classified as hazardous.
        case pressConfirmed
    }

    /// Everything a menu press returns: the evidence (nil for resolve-only), the canonical
    /// item path, the pre-press enabled report, and the hazard classification if any.
    typealias MenuPressResult = (evidence: Evidence?, menuPath: String, itemReportedEnabled: Bool, hazard: String?)

    func pressShortcut(
        pid: pid_t,
        keys: String,
        mode: ShortcutMode = .press
    ) async throws -> MenuPressResult {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        guard let shortcut = MenuQuery.Shortcut.parse(keys) else {
            throw EngineError.unparseableShortcut(keys)
        }
        guard let menuBar = AXElement(pid: pid).menuBar else {
            throw EngineError.notFound("a menu bar for pid \(pid) — background-only processes have none")
        }
        guard let match = MenuQuery.item(for: shortcut, in: menuBar) else {
            throw EngineError.notFound("a menu item carrying '\(keys)'")
        }
        return try await press(match, pid: pid, mode: mode)
    }

    /// Presses a menu item named by its title path ("File ▸ Export…" — ">" works too).
    /// Reaches everything that has no shortcut; the hazard rails, `confirm`, and
    /// `resolveOnly` behave exactly as they do for `pressShortcut`, because the press
    /// machinery is literally the same code.
    func pressMenuPath(
        pid: pid_t,
        path: String,
        mode: ShortcutMode = .press
    ) async throws -> MenuPressResult {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        let components = MenuQuery.parsePath(path)
        guard !components.isEmpty else {
            throw EngineError.notFound("menu components in '\(path)' — separate levels with '>' or '▸', e.g. \"File > Export\"")
        }
        guard let menuBar = AXElement(pid: pid).menuBar else {
            throw EngineError.notFound("a menu bar for pid \(pid) — background-only processes have none")
        }
        switch MenuQuery.item(atPath: components, in: menuBar) {
        case let .found(match):
            return try await press(match, pid: pid, mode: mode)
        case let .notFound(component, available):
            throw EngineError.menuPathNotFound(component: component, available: available)
        case let .submenu(path, items):
            throw EngineError.menuPathIsSubmenu(path: path, items: items)
        }
    }

    private func press(
        _ match: MenuQuery.Match,
        pid: pid_t,
        mode: ShortcutMode
    ) async throws -> MenuPressResult {
        let hazard = match.hazard
        // Resolve-only answers what would happen and stops. Hazardous items refuse unless the
        // caller said so explicitly, and the refusal names both the item and the consequence
        // so the agent can decide rather than guess.
        if mode == .resolveOnly {
            return (nil, match.path, match.enabled, hazard)
        }
        if let hazard, mode != .pressConfirmed {
            throw EngineError.hazardousShortcut(match.path, hazard)
        }

        // `AXEnabled` is a report, not evidence — measured: a background TextEdit's
        // "Select All" reads disabled simply because AppKit never validated a menu that was
        // never opened. So a disabled report does not gate the press; it is recorded, the
        // press runs, and the verdict comes from read-back. A genuinely disabled item then
        // yields an honest `noEffect` instead of a guess either way.

        // Window-level visual evidence. A menu press has no read-back of its own, and the
        // item's rectangle is meaningless while the menu is closed — the consequence lands in
        // the app's window. Captured window-true, so occlusion cannot fake the comparison.
        //
        // Two captures, not one. The threshold that decides "something changed" was calibrated
        // against a caret blink inside a small element rect; applied to a whole window, any
        // playing video, animated avatar, or spinner clears it continuously — so a window with
        // intrinsic motion would confirm *every* no-op shortcut. The second capture is a
        // control: if the window changes on its own while we do nothing, its pixels cannot
        // testify about what we did afterwards.
        var baseline: ScreenCapture.WindowCapture?
        var windowIsStill = false
        if ScreenCapture.isPermitted, let frame = try? windowFrame(pid: pid) {
            let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            baseline = try? await ScreenCapture.windowImage(ownedBy: pid, near: rect)
            if let baseline,
               let control = try? await ScreenCapture.windowImage(ownedBy: pid, near: baseline.windowFrame),
               let drift = ScreenDiff.changedFraction(from: baseline.image, to: control.image) {
                windowIsStill = drift <= Constants.intrinsicMotionTolerance
            }
        }
        let selectionBefore = ElementQuery.focused(pid: pid)?.selectedText

        // Accessibility only: `AXPress` is the sole meaningful way to actuate a menu item, and
        // the rungs below would aim real clicks at a closed menu's meaningless geometry.
        // `allowHardwareInput` is deliberately not forwarded for the same reason.
        let ladder = GhostLadder(accessibilityOnly: true)
        var evidence = await ladder.perform(.press, on: match.element, pid: pid)
        cache.invalidate(pid: pid)

        // Two confirmation channels, strongest first: a changed selection is semantic
        // read-back; pixels can only confirm, never refute — copy changes nothing visible.
        evidence = evidence.addingSelectionEvidence(
            before: selectionBefore,
            after: ElementQuery.focused(pid: pid)?.selectedText,
        )
        if evidence.verdict == .unverifiable, windowIsStill, let baseline,
           let after = try? await ScreenCapture.windowImage(ownedBy: pid, near: baseline.windowFrame),
           after.windowFrame == baseline.windowFrame {
            // Same window, same place: the fallback that picks the app's largest window would
            // otherwise let a window moved mid-press diff against a different one entirely.
            evidence = evidence.addingConfirmingVisualEvidence(
                delta: ScreenDiff.changedFraction(from: baseline.image, to: after.image),
            )
        }
        return (evidence, match.path, match.enabled, hazard)
    }

    /// Scrolls a scroll area — the way to reach off-screen content. Ladder-shaped like
    /// everything else: `toFraction` writes the vertical scroll bar's value and reads it
    /// back; a pixel delta posts wheel events to the process and lets the bar (or pixels)
    /// testify. The bar read-back is the strongest evidence available, because a posted
    /// scroll event's delivery is exactly the toolkit-dependent question the evidence
    /// discipline exists for.
    func scroll(
        pid: pid_t,
        label: String?,
        deltaX: Double,
        deltaY: Double,
        toFraction: Double?
    ) async throws -> (evidence: Evidence, barBefore: Double?, barAfter: Double?) {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        AXElement(pid: pid).enableManualAccessibility()
        cache.evictDeadProcesses(livePIDs: livePIDs())

        let area = try resolveScrollArea(pid: pid, label: label)
        let target = "\(area.role) '\(area.label)'"
        // Chromium and Electron expose no AXScrollArea at all (measured on Discord: the
        // whole window is AXWebArea/AXList/AXGroup), so `bar` being nil is a normal state,
        // not an error — it just means pixels are the only read-back channel.
        let bar = area.verticalScrollBar
        let barBefore = bar?.numberValue
        var attempts: [Evidence.Attempt] = []
        let cursorBefore = EventPoster.cursorLocation
        let frontBefore = await MainActor.run { EventPoster.frontmostBundleID }

        let rect = area.frame
        // Window-true captures, never a region: a region returns whatever is topmost there,
        // and a background target's rectangle photographs its occluder — a correct-looking
        // diff of somebody else's pixels. Same two-capture stillness control as the menu
        // press: a window with intrinsic motion (Discord animates constantly) cannot testify.
        var baseline: ScreenCapture.WindowCapture?
        var windowIsStill = false
        if ScreenCapture.isPermitted, let frame = try? windowFrame(pid: pid) {
            let windowRect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            baseline = try? await ScreenCapture.windowImage(ownedBy: pid, near: windowRect)
            if let baseline,
               let control = try? await ScreenCapture.windowImage(ownedBy: pid, near: baseline.windowFrame),
               let drift = ScreenDiff.changedFraction(from: baseline.image, to: control.image) {
                windowIsStill = drift <= Constants.intrinsicMotionTolerance
            }
        }

        if let toFraction {
            // Absolute positioning is a scroll-bar write or nothing: there is no way to
            // compute the wheel pixels that land at "0.5 of the document" without trusting
            // exactly the numbers this rung refuses to trust.
            guard let bar, let before = barBefore else {
                throw EngineError.notFound(
                    "a vertical scroll bar on \(target) — absolute positioning needs one; use dy to scroll relatively",
                )
            }
            let code = bar.setValue(toFraction)
            try? await Task.sleep(for: .milliseconds(250))
            let after = bar.numberValue
            cache.invalidate(pid: pid)
            let moved = after.map { abs($0 - before) > 0.001 } ?? false
            let landed = after.map { abs($0 - toFraction) <= 0.02 } ?? false
            attempts.append(.init(
                rung: .accessibility,
                outcome: code == .success
                    ? (moved ? "value write confirmed by read-back" : "reported success, scroll bar did not move")
                    : "value write failed (\(code.rawValue))",
            ))
            let verdict: Evidence.Verdict = moved ? .confirmed : .noEffect
            let readback = after.map {
                "scrollbar \(String(format: "%.3f", before)) → \(String(format: "%.3f", $0))"
                    + (landed ? "" : " (requested \(String(format: "%.3f", toFraction)))")
            }
            return (await finishScroll(
                action: "scroll(to: \(toFraction))", target: target, rung: .accessibility,
                verdict: verdict, readback: readback, attempts: attempts,
                cursorBefore: cursorBefore, frontBefore: frontBefore, area: area, pid: pid,
            ), before, after)
        }

        // Rung 1 for a labeled target: ask the app to bring it into view. Measured to be
        // the only scroll mechanism that works without the cursor — posted wheel events
        // (pixel *and* line units, location set) were ignored by AppKit and Chromium alike,
        // presumably because wheel routing belongs to the window server. The frame moving
        // afterwards is the read-back.
        if let label, let element = try? resolveNamed(pid: pid, label: label),
           element.actionNames.contains("AXScrollToVisible") {
            let before = element.frame
            let code = element.perform("AXScrollToVisible")
            try? await Task.sleep(for: .milliseconds(300))
            let after = element.frame
            cache.invalidate(pid: pid)
            if code == .success {
                if let before, let after, before != after {
                    attempts.append(.init(rung: .accessibility, outcome: "AXScrollToVisible confirmed — the element moved on screen"))
                    return (await finishScroll(
                        action: "scroll(toVisible: '\(label)')", target: target, rung: .accessibility,
                        verdict: .confirmed,
                        readback: "element frame (\(Int(before.origin.x)),\(Int(before.origin.y))) → (\(Int(after.origin.x)),\(Int(after.origin.y)))",
                        attempts: attempts,
                        cursorBefore: cursorBefore, frontBefore: frontBefore, area: area, pid: pid,
                    ), barBefore, bar?.numberValue)
                }
                if let after, let frame = try? windowFrame(pid: pid),
                   CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height).contains(after) {
                    attempts.append(.init(rung: .accessibility, outcome: "AXScrollToVisible accepted; the element is fully inside the window"))
                    return (await finishScroll(
                        action: "scroll(toVisible: '\(label)')", target: target, rung: .accessibility,
                        verdict: .confirmed, readback: "already visible", attempts: attempts,
                        cursorBefore: cursorBefore, frontBefore: frontBefore, area: area, pid: pid,
                    ), barBefore, bar?.numberValue)
                }
            }
            attempts.append(.init(
                rung: .accessibility,
                outcome: code == .success
                    ? "AXScrollToVisible reported success but the element did not move and is not verifiably visible"
                    : "AXScrollToVisible failed (\(code.rawValue))",
            ))
        }

        // Posted wheel events, aimed at the area's midpoint — kept as the fall-through and
        // for label-less pixel scrolling, with the verdict saying honestly whether anything
        // landed. Measured 2026-08-04: no toolkit honored these; see the experiment log.
        guard let rect else { throw EngineError.notFound("a frame for \(target)") }
        let aim = CGPoint(x: rect.midX, y: rect.midY)
        await EventPoster.scroll(deltaX: deltaX, deltaY: deltaY, at: aim, pid: pid)
        try? await Task.sleep(for: .milliseconds(350))
        let barAfter = bar?.numberValue
        cache.invalidate(pid: pid)

        var verdict: Evidence.Verdict
        var readback: String?
        if let barBefore, let barAfter {
            let moved = abs(barAfter - barBefore) > 0.0005
            verdict = moved ? .confirmed : .noEffect
            readback = "scrollbar \(String(format: "%.3f", barBefore)) → \(String(format: "%.3f", barAfter))"
            attempts.append(.init(
                rung: .postedEvent,
                outcome: moved
                    ? "scroll bar moved — posted wheel events were honored"
                    : "posted wheel events; the scroll bar did not move",
            ))
        } else {
            // No bar to read: already at a boundary, or the app hides its bars from AX.
            verdict = .unverifiable
            attempts.append(.init(
                rung: .postedEvent,
                outcome: "posted wheel events; no scroll bar exposes a position to read back",
            ))
        }

        var evidence = await finishScroll(
            action: "scroll(dx: \(deltaX), dy: \(deltaY))", target: target, rung: .postedEvent,
            verdict: verdict, readback: readback, attempts: attempts,
            cursorBefore: cursorBefore, frontBefore: frontBefore, area: area, pid: pid,
        )
        // Pixels as the second channel — but only when the window held still on its own,
        // and only against the same window in the same place; otherwise the diff testifies
        // about animations or a moved window, not about the scroll.
        if evidence.verdict != .confirmed, windowIsStill, let baseline,
           let after = try? await ScreenCapture.windowImage(ownedBy: pid, near: baseline.windowFrame),
           after.windowFrame == baseline.windowFrame {
            evidence = evidence.addingVisualEvidence(
                delta: ScreenDiff.changedFraction(from: baseline.image, to: after.image),
            )
        }
        return (evidence, barBefore, barAfter)
    }

    private func finishScroll(
        action: String, target: String, rung: Evidence.Rung, verdict: Evidence.Verdict,
        readback: String?, attempts: [Evidence.Attempt],
        cursorBefore: CGPoint, frontBefore: String, area: AXElement, pid: pid_t
    ) async -> Evidence {
        let cursorAfter = EventPoster.cursorLocation
        let frontAfter = await MainActor.run { EventPoster.frontmostBundleID }
        let targetBundle = await MainActor.run {
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        // A scroll that provably did nothing on web content earns the same referral a click
        // would. The web area may be the scroll area's child rather than its ancestor
        // (Safari nests them that way), so both directions are checked.
        let referral: Evidence.Referral? = if verdict == .noEffect {
            WebContent.referral(for: area, pid: pid)
                ?? area.children.first { $0.role == "AXWebArea" }
                .flatMap { WebContent.referral(for: $0, pid: pid) }
        } else {
            nil
        }
        return Evidence(
            action: action,
            target: target,
            rung: rung,
            verdict: verdict,
            readback: readback,
            pixelDelta: nil,
            focusBefore: nil,
            focusAfter: nil,
            cursorMoved: hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y) >= 1,
            frontmostChanged: frontAfter != frontBefore,
            frontmostBecameTarget: frontAfter != frontBefore && frontAfter == targetBundle,
            attempts: attempts,
            referral: referral,
        )
    }

    /// The element to aim a scroll at: an `AXScrollArea` when one exists (its scroll bar is
    /// the best read-back available), else the web area, else the labeled element or window
    /// itself. The fallbacks exist because Chromium and Electron expose **no scroll areas at
    /// all** (measured on Discord — the content is AXWebArea/AXList/AXGroup throughout), and
    /// refusing to scroll them would fail exactly the apps that need scrolling most.
    private func resolveScrollArea(pid: pid_t, label: String?) throws -> AXElement {
        if let label {
            let element = try resolveNamed(pid: pid, label: label)
            if element.role == "AXScrollArea" { return element }
            var current = element
            for _ in 0 ..< 30 {
                guard let parent = current.parent else { break }
                if parent.role == "AXScrollArea" { return parent }
                current = parent
            }
            // No enclosing scroll area: aim at the element itself — wheel events land on
            // whatever is under the point, and its scroll container need not be in the tree.
            return firstDescendant(role: "AXScrollArea", under: element) ?? element
        }
        let application = AXElement(pid: pid)
        guard let window = application.mainWindow ?? application.windows.first else {
            throw EngineError.notFound("a window for pid \(pid)")
        }
        return firstDescendant(role: "AXScrollArea", under: window)
            ?? firstDescendant(role: "AXWebArea", under: window)
            ?? window
    }

    private func firstDescendant(role: String, under root: AXElement) -> AXElement? {
        var visited = 0
        func visit(_ element: AXElement, depth: Int) -> AXElement? {
            guard depth <= Constants.scrollSearchDepth, visited < Constants.scrollSearchBudget,
                  !Task.isCancelled else { return nil }
            visited += 1
            if element.role == role { return element }
            for child in element.children {
                guard visited < Constants.scrollSearchBudget else { return nil }
                guard child.role != "AXApplication" else { continue }
                if let found = visit(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return visit(root, depth: 0)
    }

    func act(
        pid: pid_t,
        locator: Locator,
        action: GhostLadder.Action,
        allowHardwareInput: Bool
    ) async throws -> Evidence {
        let element = try resolve(locator, pid: pid)
        // How the ladder recovers when the handle dies mid-action (Electron rebuilds elements
        // on focus): re-run the *original* locator and accept the answer only when its role
        // matches what we were acting on. An equivalent element is a guess — Codex's own
        // implementation concedes uniqueness cannot be guaranteed — so the guess is taken
        // only for a provably dead handle, never to paper over a surprising read.
        // Captured while the element is provably alive. Role alone is far too weak here: for
        // the `.focused` locator the refetch query *is* `ElementQuery.focused`, the same query
        // rung 2 uses to detect text landing in the wrong field — so a role-only guard would
        // make that check compare the focused element against itself and confirm text that
        // landed somewhere else entirely. The full signature (role, label, origin, size) is
        // what distinguishes two same-role fields in one app, and a rebuilt-in-place element
        // still matches it.
        let originalSignature = element.signature
        let refetch: () -> AXElement? = {
            func accept(_ candidate: AXElement?) -> AXElement? {
                candidate?.signature == originalSignature ? candidate : nil
            }
            return switch locator {
            case .focused: accept(ElementQuery.focused(pid: pid))
            case let .point(x, y): accept(ElementQuery.hitTest(CGPoint(x: x, y: y), pid: pid))
            case let .named(label):
                {
                    let matches = ElementQuery.named(label, pid: pid).matches
                    return matches.count == 1 ? accept(matches[0].element) : nil
                }()
            }
        }
        let ladder = GhostLadder(allowHardwareInput: allowHardwareInput)
        let evidence = await ladder.perform(action, on: element, pid: pid, refetch: refetch)
        // The interface just changed; anything cached about this process is now suspect.
        cache.invalidate(pid: pid)
        return evidence
    }

    // MARK: - Internals — everything below touches non-Sendable elements

    /// Label to element, through the cache, with the ambiguity refusal every verb shares:
    /// acting on (or reading) whichever lookalike sorted first would be a coin flip.
    private func resolveNamed(pid: pid_t, label: String) throws -> AXElement {
        let matches = cache.results(for: pid, key: "find:\(label)") {
            ElementQuery.named(label, pid: pid)
        }.matches
        guard matches.count <= 1 else {
            throw EngineError.ambiguous(label, matches.map { "\($0.element.role) '\($0.element.label)'" })
        }
        guard let match = matches.first else { throw EngineError.notFound("'\(label)'") }
        return match.element
    }

    private func resolve(_ locator: Locator, pid: pid_t) throws -> AXElement {
        switch locator {
        case .focused:
            guard let element = ElementQuery.focused(pid: pid) else {
                throw EngineError.notFound("the focused element (nothing is focused)")
            }
            return element

        case let .point(x, y):
            guard let element = ElementQuery.hitTest(CGPoint(x: x, y: y), pid: pid) else {
                throw EngineError.notFound("the point (\(Int(x)), \(Int(y)))")
            }
            return element

        case let .named(label):
            let matches = ElementQuery.named(label, pid: pid).matches
            // Matching is by substring, so "delete" can name several controls. Acting on
            // whichever sorted first would be a coin flip on a possibly destructive button.
            guard matches.count <= 1 else {
                throw EngineError.ambiguous(label, matches.map { "\($0.element.role) '\($0.element.label)'" })
            }
            guard let first = matches.first else { throw EngineError.notFound("'\(label)'") }
            return first.element
        }
    }

    private func descriptor(for element: AXElement, depth: Int) -> ElementDescriptor {
        ElementDescriptor(
            role: element.role,
            label: element.label,
            value: element.value ?? "",
            depth: depth,
            frame: element.frame.map {
                .init(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height)
            },
        )
    }

    /// Read on this actor rather than hopping to the main one: `runningApplications` is safe to
    /// read from any thread, and a hop per find would reintroduce main-thread coupling.
    private nonisolated func livePIDs() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
    }
}
