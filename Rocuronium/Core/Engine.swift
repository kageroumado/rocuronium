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
    func pressShortcut(
        pid: pid_t,
        keys: String,
        allowHardwareInput: Bool
    ) async throws -> (evidence: Evidence, menuPath: String, itemReportedEnabled: Bool) {
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
        // `AXEnabled` is a report, not evidence — measured: a background TextEdit's
        // "Select All" reads disabled simply because AppKit never validated a menu that was
        // never opened. So a disabled report does not gate the press; it is recorded, the
        // press runs, and the verdict comes from read-back. A genuinely disabled item then
        // yields an honest `noEffect` instead of a guess either way.

        // Window-level visual evidence. A menu press has no read-back of its own, and the
        // item's rectangle is meaningless while the menu is closed — the consequence lands in
        // the app's window. Captured window-true, so occlusion cannot fake the comparison.
        var baseline: ScreenCapture.WindowCapture?
        if ScreenCapture.isPermitted, let frame = try? windowFrame(pid: pid) {
            baseline = try? await ScreenCapture.windowImage(
                ownedBy: pid,
                near: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
            )
        }
        let selectionBefore = ElementQuery.focused(pid: pid)?.selectedText

        let ladder = GhostLadder(allowHardwareInput: allowHardwareInput)
        var evidence = await ladder.perform(.press, on: match.element, pid: pid)
        cache.invalidate(pid: pid)

        // Two confirmation channels, strongest first: a changed selection is semantic
        // read-back; pixels can only confirm, never refute — copy changes nothing visible.
        evidence = evidence.addingSelectionEvidence(
            before: selectionBefore,
            after: ElementQuery.focused(pid: pid)?.selectedText,
        )
        if evidence.verdict == .unverifiable, let baseline,
           let after = try? await ScreenCapture.windowImage(ownedBy: pid, near: baseline.windowFrame) {
            evidence = evidence.addingConfirmingVisualEvidence(
                delta: ScreenDiff.changedFraction(from: baseline.image, to: after.image),
            )
        }
        return (evidence, match.path, match.enabled)
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
        let originalRole = element.role
        let refetch: () -> AXElement? = {
            switch locator {
            case .focused:
                let candidate = ElementQuery.focused(pid: pid)
                return candidate?.role == originalRole ? candidate : nil
            case let .point(x, y):
                let candidate = ElementQuery.hitTest(CGPoint(x: x, y: y), pid: pid)
                return candidate?.role == originalRole ? candidate : nil
            case let .named(label):
                let matches = ElementQuery.named(label, pid: pid).matches
                guard matches.count == 1, matches[0].element.role == originalRole else { return nil }
                return matches[0].element
            }
        }
        let ladder = GhostLadder(allowHardwareInput: allowHardwareInput)
        let evidence = await ladder.perform(action, on: element, pid: pid, refetch: refetch)
        // The interface just changed; anything cached about this process is now suspect.
        cache.invalidate(pid: pid)
        return evidence
    }

    // MARK: - Internals — everything below touches non-Sendable elements

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
