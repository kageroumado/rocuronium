import AppKit
import ApplicationServices

/// Everything that touches accessibility, on its own executor.
///
/// **Why this type exists.** `CommandRouter` is `@MainActor`, and under SE-0461 a `nonisolated
/// async` function runs on its *caller's* executor — so the whole reach, including synchronous
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
    /// The walks `read` handed out observation tokens for; what `read --since` diffs against.
    private let observations = TreeSnapshotStore()

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
        /// Past this share of changed elements a `read --since` diff degrades to a full
        /// read: the content was replaced, and the "diff" would just be the whole window
        /// spelled as vanishes and appearances.
        static let diffDegradeRatio = 0.6
        /// Tiny walks are exempt from the ratio: two elements changing out of three is a
        /// perfectly good diff.
        static let diffDegradeMinimumElements = 20
        /// Above this element count the tree-delta evidence channel is skipped unless
        /// `--observe`: a Discord-sized tree would double every press's latency for a channel
        /// the pixel and window-count evidence usually already cover. Discord's window walks
        /// well past this; a normal document window is a few hundred.
        static let treeEvidenceMaxElements = 3000
    }

    // MARK: - Boundary types

    /// A `Sendable` snapshot of an element, since the element itself cannot cross.
    struct ElementDescriptor: Codable, Sendable {
        let role: String
        /// The element's own name only — title, description, or placeholder — empty when it
        /// has none. Never the role description, which now has its own field: an agent must be
        /// able to tell an unlabelled control from one titled with a word like "button".
        let label: String
        /// The system's phrase for the kind ("button", "close button"). Fills the gap `label`
        /// used to paper over.
        let roleDescription: String?
        /// Tooltip text (`AXHelp`), when the app exposes one — an icon button's name without a
        /// hover.
        let help: String?
        /// `AXIdentifier` — SwiftUI's `accessibilityIdentifier`, often the symbol name.
        let identifier: String?
        /// `AXSubrole` ("AXCloseButton", "AXSecureTextField", …).
        let subrole: String?
        let value: String
        let depth: Int
        let frame: Frame?
        /// For a row with no `label` of its own: the nearest labelled sibling and the bearing
        /// to it ("right of 'Undo'"), the only handle an agent has on an unnamed control.
        let near: String?

        struct Frame: Codable, Sendable {
            let x: Double, y: Double, width: Double, height: Double
        }
    }

    /// How to find the thing to act on. Deliberately explicit: a coordinate and a label are
    /// answered by different mechanisms, and the caller should know which one replied.
    /// `role` narrows a label match when two roles share the text — a button and a menu item
    /// both titled "Restart to update" was the measured case that had no answer but raw
    /// coordinates.
    enum Locator: Sendable {
        case focused
        case named(String, role: String?, window: String?)
        case point(x: Double, y: Double)
    }

    struct FindOutcome: Sendable {
        let elements: [ElementDescriptor]
        let elementsVisited: Int
        let truncated: Bool
        let cacheHits: Int
        let cacheMisses: Int
        /// Total matches before the `limit`/`offset` page was taken — so the cap is never a
        /// silent surprise. `elements.count` is what this page shows.
        let total: Int
        let offset: Int
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
        case ambiguousWindow(String, [String])
        case unparseableShortcut(String)
        case unparseableKey(String)
        case hazardousShortcut(String, String)
        case menuPathNotFound(component: String, available: [String])
        case menuPathIsSubmenu(path: String, items: [String])
        case pathRefused(String)
        /// A sting refusal because another app's window covers the action point. Carries a
        /// machine-readable `suggestion` (typically a `park` invocation) that the router
        /// surfaces alongside the error — a suggestion, never an action taken unilaterally:
        /// the occluded-target case often wants the occluder handled instead, and only the
        /// calling agent has that context.
        case occludedTarget(String, suggestion: String)

        var isNotFound: Bool {
            if case .notFound = self { return true }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .cannotSee:
                "The display is asleep — every accessibility tree is degenerate right now, so this would report nothing found when nothing can be seen."
            case let .notFound(what):
                "No element matched \(what)."
            case let .ambiguous(query, candidates):
                "'\(query)' matched \(candidates.count) elements: \(candidates.joined(separator: ", ")). Be more specific."
            case let .ambiguousWindow(query, titles):
                "'\(query)' matched \(titles.count) windows: \(titles.map { "'\($0)'" }.joined(separator: ", ")). Name a more specific --window substring."
            case let .unparseableShortcut(keys):
                "Could not parse '\(keys)' — use forms like cmd+a, cmd+shift+z, cmd+left."
            case let .unparseableKey(keys):
                "Could not parse '\(keys)' as a named key. 'key' sends "
                    + "escape, return, tab, space, delete, forwarddelete, left/right/up/down, "
                    + "home, end, pageup, pagedown — with optional modifiers, e.g. shift+tab. "
                    + "For printable characters use 'type'; for letter shortcuts use 'shortcut'."
            case let .hazardousShortcut(path, consequence):
                "That shortcut resolves to '\(path)', which \(consequence). Pass confirm:true if that is genuinely intended. (Every app's menu bar includes the Apple menu, so session-wide items are reachable from any target.)"
            case let .menuPathNotFound(component, available):
                "No menu item '\(component)' at that level. It offers: \(available.joined(separator: ", "))."
            case let .menuPathIsSubmenu(path, items):
                "'\(path)' is a submenu, not an item — pressing it would only open it on screen. Name one of its items: \(items.joined(separator: ", "))."
            case let .pathRefused(reason):
                reason
            case let .occludedTarget(reason, _):
                reason
            }
        }
    }

    struct GroundingResult: Sendable {
        let point: CGPoint
        let confidence: Double
        let groundedBy: String
    }

    /// Proof rather than assumption: the whole point of this actor is that its work does not
    /// execute on the main thread, and that is worth being able to check at runtime instead of
    /// inferring it from isolation annotations.
    func runsOffMainThread() -> Bool { !Thread.isMainThread }

    // MARK: - Perception

    func find(
        pid: pid_t, query: String?, role: String? = nil, windowTitle: String? = nil,
        all: Bool = false, limit: Int = 20, offset: Int = 0
    ) throws -> FindOutcome {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        // A named window that does not exist is an error, not an empty result — resolve it
        // first so the caller hears "no such window", never a silent whole-app search.
        if let windowTitle { _ = try windowElement(pid: pid, titled: windowTitle) }

        // Chromium builds its tree lazily; ask once, cheap and harmless elsewhere.
        AXElement(pid: pid).enableManualAccessibility()
        cache.evictDeadProcesses(livePIDs: livePIDs())

        // `all` is its own cache key (a distinct predicate) but the page — limit/offset — is
        // applied after, over the cached full match set, so paging never re-walks.
        let key = cacheKey(all ? "@all" : query, role: role, window: windowTitle)
        let results = cache.results(for: pid, key: key) {
            if all {
                // Everything the walk can see and aim at: every element carrying a frame.
                ElementQuery.search(pid: pid, windowTitle: windowTitle) {
                    ElementQuery.roleMatches($0.role, wanted: role) && $0.frame != nil
                }
            } else if let query {
                ElementQuery.named(query, role: role, pid: pid, windowTitle: windowTitle)
            } else if let role {
                // A bare role query is a legitimate question ("list the buttons").
                ElementQuery.search(pid: pid, windowTitle: windowTitle) { ElementQuery.roleMatches($0.role, wanted: role) }
            } else {
                ElementQuery.editables(pid: pid, windowTitle: windowTitle)
            }
        }
        let statistics = cache.statistics
        let start = max(offset, 0)
        let page = results.matches.dropFirst(start).prefix(max(limit, 0))
        return FindOutcome(
            elements: page.map { descriptor(for: $0.element, depth: $0.depth) },
            elementsVisited: results.elementsVisited,
            truncated: results.truncated,
            cacheHits: statistics.hits,
            cacheMisses: statistics.misses,
            total: results.matches.count,
            offset: start,
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
        /// Observation token for this walk; a later `read --since <token>` of the same
        /// scope answers with only what changed.
        let token: String
        /// The structural diff, when `since` named a walk this one could honestly be
        /// compared against.
        let delta: Delta?
        /// Why a requested diff degraded to this full read instead. Never set silently:
        /// a caller who asked for a diff and got lines back must be told why.
        let diffNote: String?

        struct Delta: Sendable {
            let since: String
            let text: String
            let changes: Int
        }
    }

    /// Dumps the readable text of an element's subtree (by label) or the main window.
    /// The cheap way to answer "what does the app say right now" — no pixels, no model.
    ///
    /// With `since`, the walk still runs in full, but the reply is the structural diff
    /// against the walk that token named: elements appeared, vanished, values changed.
    /// Anything that would make that diff a lie — evicted token, another process, a
    /// different scope or window, a truncated walk on either side, or wholesale change —
    /// degrades to the full read with `diffNote` naming the reason.
    func read(pid: pid_t, label: String?, role: String? = nil, since: String? = nil, windowTitle: String? = nil) throws -> ReadOutcome {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        AXElement(pid: pid).enableManualAccessibility()
        cache.evictDeadProcesses(livePIDs: livePIDs())
        observations.evictDeadProcesses(livePIDs: livePIDs())

        let root: AXElement
        let scope: String
        if let label {
            // Same cache key as `find`, so a find-then-read pair costs one walk, not two.
            let element = try resolveNamed(pid: pid, label: label, role: role, windowTitle: windowTitle)
            root = element
            scope = "\(element.role) '\(element.label)'"
        } else {
            guard let window = try windowTitle.map({ try windowElement(pid: pid, titled: $0) })
                ?? primaryWindow(of: AXElement(pid: pid)) else {
                throw EngineError.notFound("a window for pid \(pid)")
            }
            root = window
            scope = "window '\(window.string(kAXTitleAttribute) ?? "")'"
        }

        let dump = TextDump.dump(root: root)
        // The window is part of the scope key: a `--since` diff must never compare a walk of
        // one window against a token from another with the same label.
        let scopeKey = "\(windowTitle.map { "win:\($0)|" } ?? "")\(label ?? "@window")|\(role ?? "*")"
        var delta: ReadOutcome.Delta?
        var diffNote: String?
        if let since {
            (delta, diffNote) = diff(
                since: since, pid: pid, scopeKey: scopeKey, scope: scope, dump: dump,
            )
        }
        let token = observations.store(TreeSnapshot(
            pid: pid, scopeKey: scopeKey, scope: scope,
            truncated: dump.truncated, nodes: dump.nodes,
        ))
        return ReadOutcome(
            scope: scope,
            lines: dump.lines.map { .init(role: $0.role, title: $0.title, value: $0.value, depth: $0.depth) },
            elementsVisited: dump.elementsVisited,
            characters: dump.characters,
            truncated: dump.truncated,
            truncationReason: dump.truncationReason,
            referral: dump.silentWebArea.flatMap { WebContent.readReferral(for: $0, pid: pid) },
            token: token,
            delta: delta,
            diffNote: diffNote,
        )
    }

    /// The `--since` decision: exactly one of the pair is non-nil. Every refusal names its
    /// reason — a wrong diff served silently would be worse than no feature at all.
    private func diff(
        since: String, pid: pid_t, scopeKey: String, scope: String, dump: TextDump.Results
    ) -> (ReadOutcome.Delta?, String?) {
        let echo = String(since.prefix(24))
        guard let previous = observations.snapshot(for: since) else {
            return (nil, "unknown or evicted token '\(echo)' — returning a full read")
        }
        guard previous.pid == pid else {
            return (nil, "token '\(echo)' belongs to another process — returning a full read")
        }
        guard previous.scopeKey == scopeKey else {
            return (nil, "token '\(echo)' covers \(previous.scope), not this query — returning a full read")
        }
        guard previous.scope == scope else {
            return (nil, "the window changed (\(previous.scope) → \(scope)) — a diff across different windows would be meaningless; returning a full read")
        }
        guard !previous.truncated, !dump.truncated else {
            let which = previous.truncated ? "earlier" : "fresh"
            return (nil, "the \(which) walk was truncated — diffing a partial tree would report unwalked elements as vanished; returning a full read")
        }
        let computed = TreeDelta.compute(from: previous.nodes, to: dump.nodes)
        let elements = max(previous.nodes.count, dump.nodes.count)
        if computed.changeRatio > Constants.diffDegradeRatio, elements > Constants.diffDegradeMinimumElements {
            return (nil, "\(Int(computed.changeRatio * 100))% of elements changed — the content was replaced wholesale, so the diff would be larger than the truth; returning a full read")
        }
        return (
            .init(since: since, text: TreeDelta.render(computed), changes: computed.changeCount),
            nil
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
    func waitFor(pid: pid_t, label: String, role: String? = nil, gone: Bool, timeout: Duration, windowTitle: String? = nil) async throws -> WaitOutcome {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        if let windowTitle { _ = try windowElement(pid: pid, titled: windowTitle) }
        AXElement(pid: pid).enableManualAccessibility()
        let clock = ContinuousClock()
        let start = clock.now
        var polls = 0

        while true {
            polls += 1
            let matches = cache.results(for: pid, key: cacheKey(label, role: role, window: windowTitle)) {
                ElementQuery.named(label, role: role, pid: pid, windowTitle: windowTitle)
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
            if elapsed >= seconds(timeout) || Task.isCancelled || EmergencyStop.isHalted {
                return WaitOutcome(satisfied: false, elapsedSeconds: elapsed, polls: polls, matches: [])
            }
            try? await Task.sleep(for: Constants.waitPollInterval)
        }
    }

    struct GuardWaitOutcome: Sendable {
        let satisfied: Bool
        let elapsedSeconds: Double
        let polls: Int
        /// The last guard evaluation's reason — what was true when the wait ended, satisfied
        /// or timed out.
        let reason: String
    }

    /// Polls a `PlanGuard` until it passes or the timeout runs out — the general form of
    /// `waitFor`, so `wait` speaks the same postcondition grammar `plan` does. The guard is
    /// evaluated against an empty step reply, so the step-relative guards (verdict,
    /// readback-contains) have nothing to match and only the state guards are meaningful here.
    func waitForGuard(pid: pid_t?, guard predicate: PlanGuard, timeout: Duration) async throws -> GuardWaitOutcome {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        let clock = ContinuousClock()
        let start = clock.now
        var polls = 0
        var reason = ""
        while true {
            polls += 1
            let result = await predicate.evaluate(reply: [:], pid: pid, engine: self)
            reason = result.reason
            let elapsed = seconds(start.duration(to: clock.now))
            if result.passed {
                return GuardWaitOutcome(satisfied: true, elapsedSeconds: elapsed, polls: polls, reason: reason)
            }
            if elapsed >= seconds(timeout) || Task.isCancelled || EmergencyStop.isHalted {
                return GuardWaitOutcome(satisfied: false, elapsedSeconds: elapsed, polls: polls, reason: reason)
            }
            try? await Task.sleep(for: Constants.waitPollInterval)
        }
    }

    /// Whether the primary window's tree holds still across `interval`: two walks that agree.
    /// The `quiet` guard's mechanism — a view that is still mutating has not finished loading.
    func treeIsQuiet(pid: pid_t, over interval: Duration) async -> Bool {
        guard let window = primaryWindow(of: AXElement(pid: pid)) else { return false }
        let first = TextDump.dump(root: window)
        guard !first.truncated else { return false }
        try? await Task.sleep(for: interval)
        guard let again = primaryWindow(of: AXElement(pid: pid)) else { return false }
        let second = TextDump.dump(root: again)
        guard !second.truncated else { return false }
        return TreeDelta.compute(from: first.nodes, to: second.nodes).isEmpty
    }

    /// Whether the primary window's tree now differs from the walk `token` recorded — the
    /// `token-changed` guard's mechanism. Nil when the token is unknown, evicted, belongs to
    /// another process, or was not a whole-window read (a labelled-subtree token cannot be
    /// honestly diffed against the whole window).
    func treeChangedSinceToken(_ token: String, pid: pid_t) -> Bool? {
        guard let snapshot = observations.snapshot(for: token), snapshot.pid == pid,
              snapshot.scopeKey == "@window|*", !snapshot.truncated else { return nil }
        guard let window = primaryWindow(of: AXElement(pid: pid)) else { return nil }
        let now = TextDump.dump(root: window)
        guard !now.truncated else { return nil }
        return !TreeDelta.compute(from: snapshot.nodes, to: now.nodes).isEmpty
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
        // no matter how finished the app is. Wake first, same as the reach's tentacle 0.
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
            if elapsed >= seconds(timeout) || Task.isCancelled || EmergencyStop.isHalted {
                return Readiness(ready: false, windows: windows, elapsedSeconds: elapsed)
            }
            try? await Task.sleep(for: Constants.launchPollInterval)
        }
    }

    private nonisolated func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The app's primary window — with the answer's *role* checked, not trusted.
    ///
    /// Measured on Safari behind the lock screen (2026-08-09): an inactive app's
    /// `AXMainWindow` attribute can answer with the **application element itself**, and a
    /// text dump rooted there walks the menu bar — 30k characters of menus and history
    /// while the actual page content never appears. Only an element that is actually a
    /// window counts; `AXWindows` answered correctly in the same state and is the fallback.
    private func primaryWindow(of application: AXElement) -> AXElement? {
        let windowRoles = ["AXWindow", "AXSheet", "AXDialog", "AXDrawer"]
        if let main = application.mainWindow, windowRoles.contains(main.role) { return main }
        return application.windows.first { windowRoles.contains($0.role) }
    }

    /// Resolves one window by a case-insensitive title substring, with the ambiguity rule
    /// every locator shares: two matches refuse and list the titles, none is notFound with
    /// the open titles named. The window-scoped verbs seed from this instead of the primary
    /// window — the answer to two "Untitled" windows, a sheet, or a second document.
    private func windowElement(pid: pid_t, titled substring: String) throws -> AXElement {
        let matches = ElementQuery.windows(pid: pid, titled: substring)
        func title(_ window: AXElement) -> String { window.string(kAXTitleAttribute) ?? "" }
        guard matches.count <= 1 else {
            throw EngineError.ambiguousWindow(substring, matches.map(title))
        }
        guard let window = matches.first else {
            let open = AXElement(pid: pid).windows
                .filter { ["AXWindow", "AXSheet", "AXDialog", "AXDrawer"].contains($0.role) }
                .map { "'\(title($0))'" }
            throw EngineError.notFound(
                "a window titled '\(substring)' for pid \(pid)"
                    + (open.isEmpty ? "" : " — open windows: \(open.joined(separator: ", "))"))
        }
        return window
    }

    /// The frame of a window, for aiming a capture or a move at it: the app's primary window,
    /// or the one whose title contains `title` when given.
    func windowFrame(pid: pid_t, title: String? = nil) throws -> ElementDescriptor.Frame {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        let window = try title.map { try windowElement(pid: pid, titled: $0) }
            ?? primaryWindow(of: AXElement(pid: pid))
        guard let window, let frame = window.frame else {
            throw EngineError.notFound("a window with a frame\(title.map { " titled '\($0)'" } ?? "") for pid \(pid)")
        }
        return .init(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
    }

    // MARK: - Actuation

    /// Moves the app's primary window — or, with `title`, the window bearing that exact
    /// title, which is how the un-park sweep returns a specific parked window — and reads
    /// its frame back as evidence.
    func moveWindow(pid: pid_t, title: String? = nil, windowTitle: String? = nil, to point: CGPoint) async throws -> WindowMove {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        let application = AXElement(pid: pid)
        let window: AXElement?
        if let windowTitle {
            // The user-facing `--window`: a substring with the shared ambiguity rule.
            window = try windowElement(pid: pid, titled: windowTitle)
        } else if let title {
            // The exact-title path the un-park sweep uses to return one specific window.
            window = application.windows.first { $0.string(kAXTitleAttribute) == title }
        } else {
            window = primaryWindow(of: application)
        }
        guard let window else {
            throw EngineError.notFound("a window\(title.map { " titled '\($0)'" } ?? "") for pid \(pid)")
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
    /// no tentacle below to permit. Accepting the flag would imply an escalation that cannot exist.
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
        mode: ShortcutMode = .press,
        observe: Bool = false
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
        return try await press(match, pid: pid, mode: mode, observe: observe)
    }

    /// Presses a menu item named by its title path ("File ▸ Export…" — ">" works too).
    /// Reaches everything that has no shortcut; the hazard rails, `confirm`, and
    /// `resolveOnly` behave exactly as they do for `pressShortcut`, because the press
    /// machinery is literally the same code.
    func pressMenuPath(
        pid: pid_t,
        path: String,
        mode: ShortcutMode = .press,
        observe: Bool = false
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
            return try await press(match, pid: pid, mode: mode, observe: observe)
        case let .notFound(component, available):
            throw EngineError.menuPathNotFound(component: component, available: available)
        case let .submenu(path, items):
            throw EngineError.menuPathIsSubmenu(path: path, items: items)
        }
    }

    private func press(
        _ match: MenuQuery.Match,
        pid: pid_t,
        mode: ShortcutMode,
        observe: Bool = false
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
        let windowsBefore = onScreenWindowCount(pid)
        let treeBaseline = treeEvidenceBaseline(pid: pid, observe: observe)

        // Accessibility only: `AXPress` is the sole meaningful way to actuate a menu item, and
        // the tentacles below would aim real clicks at a closed menu's meaningless geometry.
        // `allowHardwareInput` is deliberately not forwarded for the same reason.
        let reach = GhostReach(accessibilityOnly: true)
        var evidence = await reach.perform(.press, on: match.element, pid: pid)
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
        // A press that closes its app can never verify through the app: every read-back
        // channel above needs a live process, so a fully successful "Quit" or "Restart to
        // Update" came back ok:false / unverifiable — which invites exactly the retry a
        // just-quit app must not get (measured on Refrax's updater, 2026-08-09). The
        // process exiting right after the press *is* the read-back; poll briefly because
        // an orderly quit takes a moment.
        if evidence.verdict != .confirmed {
            // One poll loop, two read-backs. An exited process would also read as "window
            // count → 0", but "the app quit" is the message that stops a dangerous retry,
            // so the exit check wins; the count catches the rest of the window-list family
            // (File ▸ New, a closed sheet, a dismissed dialog) that element-rect, selection,
            // and same-window pixel evidence are all structurally blind to.
            var windowsAfter: Int?
            for _ in 0 ..< 6 {
                if processHasExited(pid) { break }
                let now = onScreenWindowCount(pid)
                if now != windowsBefore { windowsAfter = now; break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if processHasExited(pid) {
                evidence = evidence.confirmedByProcessExit()
            } else if let windowsAfter {
                evidence = evidence.confirmedByWindowCountChange(before: windowsBefore, after: windowsAfter)
            }
        }
        // A menu press whose consequence is a value ticking somewhere in the window — invisible
        // to selection, same-window pixels, and the window count alike. Skipped when the app
        // already quit: its tree is gone, and the exit is the read-back.
        if !processHasExited(pid) {
            evidence = foldingTreeEvidence(into: evidence, pid: pid, baseline: treeBaseline)
        }
        return (evidence, match.path, match.enabled, hazard)
    }

    /// ESRCH from a zero signal is the cheapest liveness probe there is, and it needs no
    /// main-actor hop. Within the ~1 s window this is polled, pid reuse is not a concern.
    private nonisolated func processHasExited(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    // MARK: - Status items

    /// The app's menu bar status items (`NSStatusItem`s), which live in a separate extras
    /// menu bar the window walk never reaches — `find role:AXMenuBarItem` returns nothing
    /// for them (measured on a MenuBarExtra popover app, 2026-08-22). Pid-scoped by
    /// construction, so two instances sharing a bundle id stay distinguishable.
    func statusItems(pid: pid_t) throws -> [ElementDescriptor] {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        guard let bar = AXElement(pid: pid).extrasMenuBar else { return [] }
        return bar.children.map { descriptor(for: $0, depth: 1) }
    }

    /// Presses a status item by `AXPress`, opening its menu or popover without the cursor.
    ///
    /// The press is performed directly rather than through the reach: an item whose press
    /// opens an NSMenu can block the AX call in menu tracking until the messaging timeout,
    /// so the return code routinely reads as failure for a press that fully worked. The
    /// read-back that decides is the window count — a menu or popover appearing is a window
    /// appearing, owned by the same process.
    func pressStatusItem(pid: pid_t, label: String?) async throws -> (evidence: Evidence, item: String) {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        guard let bar = AXElement(pid: pid).extrasMenuBar, !bar.children.isEmpty else {
            throw EngineError.notFound("a status item for pid \(pid) — the app installs none")
        }
        let items = bar.children
        let target: AXElement
        if let label {
            let needle = label.lowercased()
            let matches = items.filter { $0.label.lowercased().contains(needle) }
            guard matches.count <= 1 else {
                throw EngineError.ambiguous(label, matches.map { "\($0.role) '\($0.label)'" })
            }
            guard let match = matches.first else {
                throw EngineError.notFound("a status item labeled '\(label)' — this app has: "
                    + items.map { "'\($0.label)'" }.joined(separator: ", "))
            }
            target = match
        } else {
            guard items.count == 1 else {
                throw EngineError.ambiguous(
                    "the status item",
                    items.map { "\($0.role) '\($0.label)'" },
                )
            }
            target = items[0]
        }

        let itemName = target.label
        let cursorBefore = EventPoster.cursorLocation
        let frontBefore = await MainActor.run { EventPoster.frontmostBundleID }
        let windowsBefore = onScreenWindowCount(pid)
        let code = target.perform()
        cache.invalidate(pid: pid)

        var attempts: [Evidence.Attempt] = [.init(
            tentacle: .accessibility,
            outcome: code == .success
                ? "press accepted"
                : "press returned \(code.rawValue) — for a status item this can mean the AX call "
                    + "blocked in menu tracking, not that nothing happened; the window count decides",
        )]
        var verdict = Evidence.Verdict.unverifiable
        var readback: String?
        for _ in 0 ..< 6 {
            let now = onScreenWindowCount(pid)
            if now != windowsBefore {
                verdict = .confirmed
                readback = "the target's on-screen window count changed \(windowsBefore) → \(now)"
                attempts.append(.init(
                    tentacle: .accessibility,
                    outcome: "window count \(windowsBefore) → \(now) — its menu or popover is open",
                ))
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let cursorAfter = EventPoster.cursorLocation
        let frontAfter = await MainActor.run { EventPoster.frontmostBundleID }
        let targetBundle = await MainActor.run {
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        let evidence = Evidence(
            action: "statusItem(press)",
            target: "AXMenuBarItem '\(itemName)'",
            tentacle: .accessibility,
            verdict: verdict,
            readback: readback,
            pixelDelta: nil,
            focusBefore: nil,
            focusAfter: nil,
            cursorMoved: hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y) >= 1,
            frontmostChanged: frontAfter != frontBefore,
            frontmostBecameTarget: frontAfter != frontBefore && frontAfter == targetBundle,
            attempts: attempts,
            referral: nil,
        )
        return (evidence, itemName)
    }

    /// Posts a bare named key (Escape, Return, arrows…) to the process — the verb for keys
    /// that are neither text (`type`) nor menu-reachable (`shortcut`). The measured need:
    /// dismissing a native file-picker dialog wants a plain Escape, which no other verb
    /// could send (trial log, 2026-08-06).
    ///
    /// Honesty note baked into the evidence: posted keycode events are delivered per-pid and
    /// work on AppKit, but Electron/Chromium ignore keycode-only events entirely (measured on
    /// Discord). Confirmation channels are the focused element changing and window pixels;
    /// a quiet result stays `unverifiable` rather than `noEffect`, because a key that merely
    /// moves a caret changes almost nothing a window-scale diff can see.
    /// How a bare key reaches its target: per-pid posted events (the ghost default), or the
    /// console pipeline (session-level — the only channel key-equivalent dispatch hears,
    /// gated by the router like all hardware input because it lands in global focus).
    enum KeyDelivery: Sendable {
        case process
        case session
    }

    func pressKey(pid: pid_t, keys: String, delivery: KeyDelivery = .process) async throws -> Evidence {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        guard let chord = EventPoster.KeyChord.parse(keys) else {
            throw EngineError.unparseableKey(keys)
        }

        let cursorBefore = EventPoster.cursorLocation
        let frontBefore = await MainActor.run { EventPoster.frontmostBundleID }
        let focusedBefore = ElementQuery.focused(pid: pid)
        let focusBefore = focusedBefore?.signature
        let target = focusedBefore.map { "\($0.role) '\($0.label)'" } ?? "pid \(pid)"

        // Same two-capture stillness control as the menu press: a key's consequence lands
        // somewhere in the window (a dialog closing, a row highlight moving), and a window
        // with intrinsic motion cannot testify.
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

        let windowsBefore = onScreenWindowCount(pid)
        switch delivery {
        case .process:
            await EventPoster.sendKey(chord.keyCode, modifiers: chord.flags, pid: pid)
        case .session:
            await HardwareInput.pressKey(chord)
        }
        try? await Task.sleep(for: .milliseconds(300))
        cache.invalidate(pid: pid)

        let tentacle: Evidence.Tentacle = delivery == .session ? .hardwareInput : .postedEvent
        let focusAfter = ElementQuery.focused(pid: pid)?.signature
        let focusChanged = focusAfter != focusBefore
        let outcome = switch (delivery, focusChanged) {
        case (.process, true): "key posted; the focused element changed"
        case (.process, false): "key posted (per-pid keycode event — AppKit honors these; Electron/Chromium ignore them)"
        case (.session, true): "key pressed on the console pipeline; the focused element changed"
        case (.session, false): "key pressed on the console pipeline (reaches key-equivalent dispatch in the frontmost app)"
        }
        let attempts: [Evidence.Attempt] = [.init(tentacle: tentacle, outcome: outcome)]

        let cursorAfter = EventPoster.cursorLocation
        let frontAfter = await MainActor.run { EventPoster.frontmostBundleID }
        let targetBundle = await MainActor.run {
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        var evidence = Evidence(
            action: "key(\(chord.name))",
            target: target,
            tentacle: tentacle,
            verdict: focusChanged ? .confirmed : .unverifiable,
            readback: nil,
            pixelDelta: nil,
            focusBefore: focusBefore,
            focusAfter: focusAfter,
            cursorMoved: hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y) >= 1,
            frontmostChanged: frontAfter != frontBefore,
            frontmostBecameTarget: frontAfter != frontBefore && frontAfter == targetBundle,
            attempts: attempts,
            referral: nil,
        )
        if evidence.verdict == .unverifiable, windowIsStill, let baseline,
           let after = try? await ScreenCapture.windowImage(ownedBy: pid, near: baseline.windowFrame),
           after.windowFrame == baseline.windowFrame {
            evidence = evidence.addingConfirmingVisualEvidence(
                delta: ScreenDiff.changedFraction(from: baseline.image, to: after.image),
            )
        }
        // Escape's whole job is often a dialog vanishing — the window-list read-back is the
        // channel that can actually see that (loose end 7). A shorter poll than the press
        // verbs': arrows and other caret keys legitimately stay unverifiable, and the 300 ms
        // settle above already covers most dismissal animations.
        if evidence.verdict != .confirmed {
            for _ in 0 ..< 3 {
                let now = onScreenWindowCount(pid)
                if now != windowsBefore {
                    evidence = evidence.confirmedByWindowCountChange(before: windowsBefore, after: now)
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return evidence
    }

    /// Scrolls a scroll area — the way to reach off-screen content. Reach-shaped like
    /// everything else: `toFraction` writes the vertical scroll bar's value and reads it
    /// back; a pixel delta posts wheel events to the process and lets the bar (or pixels)
    /// testify. The bar read-back is the strongest evidence available, because a posted
    /// scroll event's delivery is exactly the toolkit-dependent question the evidence
    /// discipline exists for.
    func scroll(
        pid: pid_t,
        label: String?,
        role: String? = nil,
        deltaX: Double,
        deltaY: Double,
        toFraction: Double?
    ) async throws -> (evidence: Evidence, barBefore: Double?, barAfter: Double?) {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        AXElement(pid: pid).enableManualAccessibility()
        cache.evictDeadProcesses(livePIDs: livePIDs())

        let area = try resolveScrollArea(pid: pid, label: label, role: role)
        let target = "\(area.role) '\(area.label)'"
        // Chromium and Electron expose no AXScrollArea at all (measured on Discord: the
        // whole window is AXWebArea/AXList/AXGroup), so `bar` being nil is a normal state,
        // not an error — it just means pixels are the only read-back channel.
        let bar = verticalScrollBar(of: area)
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
            // exactly the numbers this tentacle refuses to trust.
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
                tentacle: .accessibility,
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
                action: "scroll(to: \(toFraction))", target: target, tentacle: .accessibility,
                verdict: verdict, readback: readback, attempts: attempts,
                cursorBefore: cursorBefore, frontBefore: frontBefore, area: area, pid: pid,
            ), before, after)
        }

        // Tentacle 1 for a labeled target: ask the app to bring it into view. Measured to be
        // the only scroll mechanism that works without the cursor — posted wheel events
        // (pixel *and* line units, location set) were ignored by AppKit and Chromium alike,
        // presumably because wheel routing belongs to the window server. The frame moving
        // afterwards is the read-back.
        // Attempted whether or not the element advertises the action, because advertisement
        // and honoring disagree in both directions (measured 2026-08-24: SwiftUI static
        // text omits the action yet accepts the call — and does nothing; Mail's list rows
        // refuse it outright with -25205). The frame read-back below is the judge.
        if let label, let element = try? resolveNamed(pid: pid, label: label, role: role) {
            let advertised = element.actionNames.contains("AXScrollToVisible")
            let before = element.frame
            let code = element.perform("AXScrollToVisible")
            try? await Task.sleep(for: .milliseconds(300))
            let after = element.frame
            cache.invalidate(pid: pid)
            if code == .success {
                if let before, let after, before != after {
                    attempts.append(.init(tentacle: .accessibility, outcome: "AXScrollToVisible confirmed — the element moved on screen"))
                    return (await finishScroll(
                        action: "scroll(toVisible: '\(label)')", target: target, tentacle: .accessibility,
                        verdict: .confirmed,
                        readback: "element frame (\(Int(before.origin.x)),\(Int(before.origin.y))) → (\(Int(after.origin.x)),\(Int(after.origin.y)))",
                        attempts: attempts,
                        cursorBefore: cursorBefore, frontBefore: frontBefore, area: area, pid: pid,
                    ), barBefore, bar?.numberValue)
                }
                if let after, let frame = try? windowFrame(pid: pid),
                   CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height).contains(after) {
                    attempts.append(.init(tentacle: .accessibility, outcome: "AXScrollToVisible accepted; the element is fully inside the window"))
                    return (await finishScroll(
                        action: "scroll(toVisible: '\(label)')", target: target, tentacle: .accessibility,
                        verdict: .confirmed, readback: "already visible", attempts: attempts,
                        cursorBefore: cursorBefore, frontBefore: frontBefore, area: area, pid: pid,
                    ), barBefore, bar?.numberValue)
                }
            }
            attempts.append(.init(
                tentacle: .accessibility,
                outcome: code == .success
                    ? "AXScrollToVisible reported success but the element did not move and is not verifiably visible"
                    : "AXScrollToVisible failed (\(code.rawValue))"
                    + (advertised ? "" : " — the element does not advertise the action"),
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
                tentacle: .postedEvent,
                outcome: moved
                    ? "scroll bar moved — posted wheel events were honored"
                    : "posted wheel events; the scroll bar did not move",
            ))
        } else {
            // No bar to read: already at a boundary, or the app hides its bars from AX.
            verdict = .unverifiable
            attempts.append(.init(
                tentacle: .postedEvent,
                outcome: "posted wheel events; no scroll bar exposes a position to read back",
            ))
        }

        var evidence = await finishScroll(
            action: "scroll(dx: \(deltaX), dy: \(deltaY))", target: target, tentacle: .postedEvent,
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

    struct ScrollSearchResult: Sendable {
        let evidence: Evidence
        let barBefore: Double?
        let barAfter: Double?
        let steps: Int
        /// Screen rectangle of the sighted text, ready to aim a click at.
        let foundAt: ElementDescriptor.Frame?
        /// The step budget ran out with more document left — call again to keep looking.
        let callAgain: Bool
    }

    /// Scrolls until OCR sights `needle` in the frame — deterministic where pixel deltas
    /// blindly over- or undershoot.
    ///
    /// Each iteration captures the target's window (window-true, occlusion-proof), OCRs it
    /// locally (~100 ms, `TextSighting`), and stops the moment the text is legible — so the
    /// loop terminates on *sight*, not on a guessed distance. Sightings only count inside
    /// the scroll area's own rectangle, or a match in a sidebar would stop a search of the
    /// list next to it. The stepper is the scroll bar where one is exposed (step sized from
    /// the bar's thumb, with overlap, so a screenful can never skip past the needle between
    /// frames); posted wheels are the fallback, and two consecutive frames with identical
    /// legible text end the loop honestly — the end of the document, or a toolkit that
    /// ignores posted wheels.
    func scrollUntilText(
        pid: pid_t,
        label: String?,
        role: String?,
        needle: String,
        deltaY: Double,
        maxSteps: Int
    ) async throws -> ScrollSearchResult {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        guard ScreenCapture.isPermitted else {
            throw EngineError.pathRefused(
                "'untilText' needs Screen Recording — the loop is OCR over captured frames. Grant it, or use 'scroll' with a label (AXScrollToVisible) instead.",
            )
        }
        AXElement(pid: pid).enableManualAccessibility()
        cache.evictDeadProcesses(livePIDs: livePIDs())

        let area = try resolveScrollArea(pid: pid, label: label, role: role)
        let target = "\(area.role) '\(area.label)'"
        let areaFrame = area.frame
        let bar = verticalScrollBar(of: area)
        let barBefore = bar?.numberValue
        let cursorBefore = EventPoster.cursorLocation
        let frontBefore = await MainActor.run { EventPoster.frontmostBundleID }
        let direction: Double = deltaY < 0 ? -1 : 1
        // Step by most of a viewport, never a full one: the overlap is what guarantees text
        // cannot scroll through unseen between two frames. The thumb's share of its track is
        // the viewport's share of the document; without a readable thumb, small fixed steps.
        let stepFraction = max(0.02, 0.8 * (thumbFraction(of: bar) ?? 0.075))

        var attempts: [Evidence.Attempt] = []
        var steps = 0
        var previousFingerprint: String?
        var stalledFrames = 0
        var reachedEnd = false

        while steps < maxSteps, !Task.isCancelled, !EmergencyStop.isHalted {
            guard let frame = try? windowFrame(pid: pid),
                  let capture = try? await ScreenCapture.windowImage(
                      ownedBy: pid,
                      near: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                  )
            else {
                attempts.append(.init(tentacle: .accessibility, outcome: "could not capture the window to OCR"))
                break
            }
            let sightings = TextSighting.sight(in: capture.image)
            let inArea = sightings.filter { sighting in
                guard let areaFrame else { return true }
                return TextSighting.screenRect(of: sighting, in: capture.windowFrame)
                    .intersects(areaFrame)
            }
            if let hit = TextSighting.find(needle, in: inArea) {
                let rect = TextSighting.screenRect(of: hit, in: capture.windowFrame)
                attempts.append(.init(
                    tentacle: bar != nil ? .accessibility : .postedEvent,
                    outcome: "OCR sighted '\(hit.text.prefix(60))' after \(steps) step(s)",
                ))
                cache.invalidate(pid: pid)
                return ScrollSearchResult(
                    evidence: await finishScroll(
                        action: "scroll(untilText: '\(needle)')", target: target,
                        tentacle: bar != nil ? .accessibility : .postedEvent,
                        verdict: .confirmed,
                        readback: "sighted at (\(Int(rect.midX)), \(Int(rect.midY))) — line: '\(hit.text.prefix(80))'",
                        attempts: attempts,
                        cursorBefore: cursorBefore,
                        frontBefore: frontBefore,
                        area: area, pid: pid,
                    ),
                    barBefore: barBefore, barAfter: bar?.numberValue, steps: steps,
                    foundAt: .init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height),
                    callAgain: false,
                )
            }

            // Nothing changing between frames means scrolling has stopped working: the end
            // of the document, or a target that ignores the mechanism. Two identical frames,
            // not one — a slow renderer can serve a stale frame once.
            let fingerprint = TextSighting.fingerprint(of: inArea)
            if fingerprint == previousFingerprint {
                stalledFrames += 1
                if stalledFrames >= 2 { break }
            } else {
                stalledFrames = 0
            }
            previousFingerprint = fingerprint

            if let bar, let position = bar.numberValue {
                let next = min(1, max(0, position + direction * stepFraction))
                if abs(next - position) < 0.0005 {
                    reachedEnd = true
                    break
                }
                bar.setValue(next)
            } else if let areaFrame {
                await EventPoster.scroll(
                    deltaX: 0, deltaY: direction * 400,
                    at: CGPoint(x: areaFrame.midX, y: areaFrame.midY), pid: pid,
                )
            } else {
                attempts.append(.init(tentacle: .postedEvent, outcome: "no scroll bar and no frame to aim wheels at"))
                break
            }
            steps += 1
            try? await Task.sleep(for: .milliseconds(250))
        }

        cache.invalidate(pid: pid)
        let barAfter = bar?.numberValue
        let exhausted = steps >= maxSteps && !reachedEnd
        let barIgnored = bar == nil && stalledFrames >= 2
        attempts.append(.init(
            tentacle: bar != nil ? .accessibility : .postedEvent,
            outcome: reachedEnd
                ? "scanned to the \(direction > 0 ? "end" : "top") without sighting '\(needle)'"
                : exhausted
                    ? "step budget spent (\(steps)); more document remains — call again to continue"
                    : "frames stopped changing after \(steps) step(s) — the end of the content, or the target ignores this scroll mechanism",
        ))
        // A posted-wheel loop that provably moved nothing is a noEffect, and finishScroll
        // attaches the web-content referral to that verdict on its own.
        let evidence = await finishScroll(
            action: "scroll(untilText: '\(needle)')", target: target,
            tentacle: bar != nil ? .accessibility : .postedEvent,
            verdict: barIgnored ? .noEffect : .unverifiable,
            readback: barAfter.map { after in
                barBefore.map { "scrollbar \(String(format: "%.3f", $0)) → \(String(format: "%.3f", after))" }
                    ?? "scrollbar at \(String(format: "%.3f", after))"
            },
            attempts: attempts,
            cursorBefore: cursorBefore,
            frontBefore: frontBefore,
            area: area, pid: pid,
        )
        return ScrollSearchResult(
            evidence: evidence,
            barBefore: barBefore, barAfter: barAfter, steps: steps,
            foundAt: nil,
            callAgain: exhausted,
        )
    }

    /// The scroll bar thumb's share of its track ≈ the viewport's share of the document.
    /// Read from the bar's `AXValueIndicator` child; nil when the bar hides its thumb from
    /// accessibility.
    private func thumbFraction(of bar: AXElement?) -> Double? {
        guard let bar, let barFrame = bar.frame, barFrame.height > 0 else { return nil }
        guard let thumb = bar.children.first(where: { $0.role == "AXValueIndicator" }),
              let thumbFrame = thumb.frame
        else { return nil }
        let fraction = thumbFrame.height / barFrame.height
        return (0.005 ... 1).contains(fraction) ? fraction : nil
    }

    private func finishScroll(
        action: String, target: String, tentacle: Evidence.Tentacle, verdict: Evidence.Verdict,
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
            tentacle: tentacle,
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
    private func resolveScrollArea(pid: pid_t, label: String?, role: String? = nil) throws -> AXElement {
        if let label {
            let element = try resolveNamed(pid: pid, label: label, role: role)
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
        guard let window = primaryWindow(of: AXElement(pid: pid)) else {
            throw EngineError.notFound("a window for pid \(pid)")
        }
        return firstDescendant(role: "AXScrollArea", under: window)
            ?? firstDescendant(role: "AXWebArea", under: window)
            ?? window
    }

    /// The vertical scroll bar of an area, by attribute or by role walk.
    ///
    /// Overlay scrollers (the default since 10.7) are the suspected reason the
    /// `AXVerticalScrollBar` *attribute* is absent on modern AppKit — measured 2026-08-04 in
    /// Notes and Mail: the enclosing scroll area answers nothing for the attribute while a
    /// child `AXScrollBar` element sits right there with a numeric value. So the attribute is
    /// tried first, then a bounded two-level walk of the area's children. Taller-than-wide
    /// picks the vertical bar; horizontal bars carry the same role.
    private func verticalScrollBar(of area: AXElement) -> AXElement? {
        if let bar = area.verticalScrollBar { return bar }
        var candidates: [AXElement] = []
        for child in area.children {
            if child.role == "AXScrollBar" {
                candidates.append(child)
            } else {
                candidates.append(contentsOf: child.children.filter { $0.role == "AXScrollBar" })
            }
        }
        return candidates.first { bar in
            guard bar.numberValue != nil, let frame = bar.frame else { return false }
            return frame.height > frame.width
        }
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

    /// A hit test answers with the *deepest* element at the point, and on SwiftUI that is
    /// routinely a plain AXGroup inside the actual control — measured on Refrax: the button's
    /// coordinate resolved to a group with no press action, so the ghost click had nothing to
    /// press and the posted event was a no-effect. For click-shaped actions the enclosing
    /// pressable is what the caller meant; for text the deepest element is right, so the
    /// ascent is per-action, not part of resolution.
    private nonisolated func ascendToPressable(_ element: AXElement) -> AXElement {
        if element.pressishAction != nil { return element }
        var current = element
        for _ in 0 ..< 5 {
            guard let parent = current.parent else { break }
            // A window or the app itself is never the button the caller aimed at.
            if ["AXWindow", "AXSheet", "AXApplication"].contains(parent.role) { break }
            if parent.pressishAction != nil { return parent }
            current = parent
        }
        return element
    }

    /// The before half of the tree-delta evidence channel: one bounded walk of the primary
    /// window, taken before an action so the after-walk has something to diff against. Nil
    /// when no diff will be honest — no window, a truncated walk (which would report unwalked
    /// elements as vanished), or a tree too large to walk twice without taxing every press
    /// (unless the caller opted in with `observe`).
    /// One walk of a window's tree — the primary window, or the one whose title contains
    /// `windowTitle`. Nil when there is no such window or the walk was truncated (a partial
    /// tree cannot be diffed honestly). The shared primitive under every tree-delta channel.
    private func windowNodes(pid: pid_t, windowTitle: String?) -> [TreeSnapshot.Node]? {
        let window: AXElement?
        if let windowTitle {
            window = try? windowElement(pid: pid, titled: windowTitle)
        } else {
            window = primaryWindow(of: AXElement(pid: pid))
        }
        guard let window else { return nil }
        let dump = TextDump.dump(root: window)
        guard !dump.truncated else { return nil }
        return dump.nodes
    }

    private func treeEvidenceBaseline(pid: pid_t, observe: Bool, windowTitle: String? = nil) -> [TreeSnapshot.Node]? {
        guard let nodes = windowNodes(pid: pid, windowTitle: windowTitle) else { return nil }
        guard observe || nodes.count <= Constants.treeEvidenceMaxElements else { return nil }
        return nodes
    }

    /// The after half: re-walks the window and folds the structural diff into the evidence. A
    /// missing or truncated after-walk leaves the evidence exactly as it was — this channel
    /// only ever adds signal, never removes it.
    private func foldingTreeEvidence(
        into evidence: Evidence, pid: pid_t, baseline: [TreeSnapshot.Node]?, windowTitle: String? = nil
    ) -> Evidence {
        guard let baseline, let after = windowNodes(pid: pid, windowTitle: windowTitle) else { return evidence }
        return evidence.addingTreeEvidence(TreeDelta.compute(from: baseline, to: after))
    }

    func act(
        pid: pid_t,
        locator: Locator,
        action: GhostReach.Action,
        allowHardwareInput: Bool,
        observe: Bool = false,
        clickOptions: GhostReach.ClickOptions = .init()
    ) async throws -> Evidence {
        var groundingResult: GroundingResult?
        var effectiveLocator = locator
        var element: AXElement
        do {
            element = try resolve(locator, pid: pid)
        } catch let error as EngineError where error.isNotFound {
            if case let .named(label, _, _) = locator {
                let result = try await ground(instruction: label, pid: pid)
                groundingResult = result
                effectiveLocator = .point(x: result.point.x, y: result.point.y)
                element = try resolve(effectiveLocator, pid: pid)
            } else {
                throw error
            }
        }
        let wantsPress = if case .setText = action { false } else { true }
        if wantsPress, case .point = effectiveLocator {
            element = ascendToPressable(element)
        }
        // How the reach recovers when the handle dies mid-action (Electron rebuilds elements
        // on focus): re-run the *original* locator and accept the answer only when its role
        // matches what we were acting on. An equivalent element is a guess — Codex's own
        // implementation concedes uniqueness cannot be guaranteed — so the guess is taken
        // only for a provably dead handle, never to paper over a surprising read.
        // Captured while the element is provably alive. Role alone is far too weak here: for
        // the `.focused` locator the refetch query *is* `ElementQuery.focused`, the same query
        // tentacle 2 uses to detect text landing in the wrong field — so a role-only guard would
        // make that check compare the focused element against itself and confirm text that
        // landed somewhere else entirely. The full signature (role, label, origin, size) is
        // what distinguishes two same-role fields in one app, and a rebuilt-in-place element
        // still matches it.
        let originalSignature = element.signature
        let refetch: () -> AXElement? = { [wantsPress, effectiveLocator] in
            func accept(_ candidate: AXElement?) -> AXElement? {
                candidate?.signature == originalSignature ? candidate : nil
            }
            return switch effectiveLocator {
            case .focused: accept(ElementQuery.focused(pid: pid))
            case let .point(x, y):
                // The same ascent as resolution, so the refetched candidate is compared
                // against the element actually acted on, not the deep group under the point.
                accept(ElementQuery.hitTest(CGPoint(x: x, y: y), pid: pid).map {
                    wantsPress ? self.ascendToPressable($0) : $0
                })
            case let .named(label, role, window):
                {
                    let matches = ElementQuery.named(label, role: role, pid: pid, windowTitle: window).matches
                    return matches.count == 1 ? accept(matches[0].element) : nil
                }()
            }
        }
        // Window-level visual evidence for click-shaped actions, exactly as the menu press
        // takes it. The reach diffs the *element's* rectangle, and a button's own pixels
        // return to rest immediately while the consequence lands elsewhere in the window —
        // measured on Calculator: pressing '1' changed the display, the button's rect read
        // quiet, and the verdict came back a false noEffect. Same two-capture stillness
        // control; a window animating on its own cannot testify.
        // When the original locator named a window, evidence is scoped to it: the pixel
        // baseline and the tree walk both aim at that window rather than the primary one.
        let windowTitle: String? = if case let .named(_, _, window) = locator { window } else { nil }
        var baseline: ScreenCapture.WindowCapture?
        var windowIsStill = false
        if wantsPress, ScreenCapture.isPermitted, let frame = try? windowFrame(pid: pid, title: windowTitle) {
            let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            baseline = try? await ScreenCapture.windowImage(ownedBy: pid, near: rect)
            if let baseline,
               let control = try? await ScreenCapture.windowImage(ownedBy: pid, near: baseline.windowFrame),
               let drift = ScreenDiff.changedFraction(from: baseline.image, to: control.image) {
                windowIsStill = drift <= Constants.intrinsicMotionTolerance
            }
        }

        // Taken before the press for the same reason the pixel baseline is: the window-count
        // read-back below compares against the world as it was, not as the press left it.
        let windowsBefore = wantsPress ? onScreenWindowCount(pid) : nil
        // The tree-delta channel's before-walk, same timing and same reason.
        let treeBaseline = wantsPress ? treeEvidenceBaseline(pid: pid, observe: observe, windowTitle: windowTitle) : nil

        let reach = GhostReach(allowHardwareInput: allowHardwareInput, clickOptions: clickOptions)
        var evidence = await reach.perform(action, on: element, pid: pid, refetch: refetch)
        // The interface just changed; anything cached about this process is now suspect.
        cache.invalidate(pid: pid)

        if evidence.verdict != .confirmed, windowIsStill, let baseline,
           let after = try? await ScreenCapture.windowImage(ownedBy: pid, near: baseline.windowFrame),
           after.windowFrame == baseline.windowFrame {
            // Confirm-only, unlike the element-rect channel: the element's own quiet pixels
            // may refute a click, but a quiet *window* must not — the consequence of a
            // legitimate click can be a popover on another window or no pixels at all.
            evidence = evidence.addingConfirmingVisualEvidence(
                delta: ScreenDiff.changedFraction(from: baseline.image, to: after.image),
            )
        }
        // The window-list family: a click whose consequence is a window or sheet appearing
        // or vanishing is invisible to every channel above — the watched rectangle itself
        // goes away, or the change lands outside it (loose end 7's measured cases: Cancel
        // dismissing its own sheet read noEffect, a close button read unverified). Polled
        // briefly because window creation and dismissal animate.
        if evidence.verdict != .confirmed, let windowsBefore {
            for _ in 0 ..< 6 {
                let now = onScreenWindowCount(pid)
                if now != windowsBefore {
                    evidence = evidence.confirmedByWindowCountChange(before: windowsBefore, after: now)
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        // The tree-delta channel, last because it is the strongest at seeing consequences the
        // pixel and window-count channels miss (a value ticking on a sibling), and because
        // "what changed" is worth more in the reply than "something changed". Folded even on a
        // confirmed verdict: the diff is free once the baseline was taken, and it is the
        // reply's most legible account of what the press did.
        evidence = foldingTreeEvidence(into: evidence, pid: pid, baseline: treeBaseline, windowTitle: windowTitle)
        if let grounding = groundingResult {
            evidence.groundedBy = grounding.groundedBy
        }
        return evidence
    }

    // MARK: - OCR rows

    /// One line of on-screen text with its screen-point rectangle — the row shape `find` and
    /// `read` return for a window whose accessibility tree is empty or lying. `label` is the
    /// text; the frame is where a follow-up coordinate click aims.
    struct OCRRow: Sendable {
        let text: String
        let frame: ElementDescriptor.Frame
    }

    /// OCRs the target's window into text rows in reading order — top to bottom, then left to
    /// right within a line. No model and no tokens (~100 ms on Vision's fast path), the same
    /// primitive `scroll --until-text` uses. Needs Screen Recording; refuses honestly without
    /// it, and while the display sleeps.
    func ocrRows(pid: pid_t, windowTitle: String? = nil) async throws -> [OCRRow] {
        guard DisplayWake.perceptionIsReliable else { throw EngineError.cannotSee }
        guard ScreenCapture.isPermitted else { throw GroundingError.screenRecordingRequired }
        let frame = try windowFrame(pid: pid, title: windowTitle)
        let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        let capture = try await ScreenCapture.windowImage(ownedBy: pid, near: rect)
        let rows = TextSighting.sight(in: capture.image).map { sighting -> OCRRow in
            let r = TextSighting.screenRect(of: sighting, in: capture.windowFrame)
            return OCRRow(
                text: sighting.text,
                frame: .init(x: r.minX, y: r.minY, width: r.width, height: r.height),
            )
        }
        // Reading order: rows on roughly the same baseline (within half the taller row's
        // height) read left-to-right; otherwise top-to-bottom. OCR returns lines in no
        // dependable order, and a caller pays for a jumbled read in comprehension.
        return rows.sorted { first, second in
            let band = max(first.frame.height, second.frame.height) * 0.5
            if abs(first.frame.y - second.frame.y) > band { return first.frame.y < second.frame.y }
            return first.frame.x < second.frame.x
        }
    }

    // MARK: - Vision grounding

    private let detector = DetectorBackend()
    private let vlm = MLXBackend()

    private func ground(instruction: String, pid: pid_t) async throws -> GroundingResult {
        guard ScreenCapture.isPermitted else {
            throw GroundingError.screenRecordingRequired
        }
        guard DisplayWake.perceptionIsReliable else {
            throw EngineError.cannotSee
        }

        let frame = try windowFrame(pid: pid)
        let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        let capture = try await ScreenCapture.windowImage(ownedBy: pid, near: rect)

        if detector.isAvailable {
            let candidates = try await detector.locate(instruction, in: capture.image)
            if let best = candidates.first {
                let center = CGPoint(x: best.rect.midX, y: best.rect.midY)
                let screen = imageToScreen(center, imageWidth: capture.image.width, imageHeight: capture.image.height, windowFrame: capture.windowFrame)
                return GroundingResult(point: screen, confidence: best.confidence, groundedBy: "detector")
            }
        }

        if await vlm.isAvailable {
            let candidates = try await vlm.locate(instruction, in: capture.image)
            if let best = candidates.first {
                let center = CGPoint(x: best.rect.midX, y: best.rect.midY)
                let screen = imageToScreen(center, imageWidth: capture.image.width, imageHeight: capture.image.height, windowFrame: capture.windowFrame)
                return GroundingResult(point: screen, confidence: best.confidence, groundedBy: "vlm")
            }
        }

        throw EngineError.notFound("'\(instruction)' (AX tree empty, vision grounding found nothing)")
    }

    private nonisolated func imageToScreen(
        _ imagePoint: CGPoint, imageWidth: Int, imageHeight: Int, windowFrame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: windowFrame.minX + (imagePoint.x / CGFloat(imageWidth)) * windowFrame.width,
            y: windowFrame.minY + (imagePoint.y / CGFloat(imageHeight)) * windowFrame.height
        )
    }

    // MARK: - Cursor paths

    struct TraceResult: Sendable {
        let outcome: HardwareInput.TraceOutcome
        let plannedEnd: CGPoint
        let pathLength: Double
        let durationSeconds: Double
        let sampleCount: Int
        /// On-screen window counts for the target app around the gesture — the cheap
        /// semantic evidence for hover: a flyout or menu appearing is a window appearing.
        let windowsBefore: Int?
        let windowsAfter: Int?
        /// Who owns the topmost window at the action point, when it is not the target.
        let endpointOwner: String?
        /// What the gesture revealed in the window's tree — the tooltip that appeared, the
        /// controls that unhid. A hover that returns no text is half a verb; this is the
        /// other half. Nil when no pid was given or the tree could not be diffed.
        let treeChanges: Int?
        let treeDelta: String?
    }

    /// Moves the real cursor along a path (`button: nil`) or drags along it (button held).
    ///
    /// Hardware-tentacle by measurement, not by policy: the cursor-paths experiment (2026-08-20)
    /// showed per-pid posted motion is dropped wholesale — tracking areas, `.onHover`,
    /// WebKit hover, content drags and title-bar drags all stayed silent, background and
    /// frontmost alike. Hover and drag exist only with the real pointer; the presence gate
    /// lives in the router, like `activate`'s.
    func trace(
        pid: pid_t?,
        waypoints: [CGPoint],
        label: String?,
        role: String?,
        duration: Duration?,
        easing: PathPlan.Easing,
        button: HardwareInput.MouseButton?,
        restoreCursor: Bool,
        windowTitle: String? = nil,
        dwell: Duration? = nil,
    ) async throws -> TraceResult {
        // The tree is only consulted for a labeled endpoint, but an asleep display voids
        // the gesture's entire purpose too: nothing tracks a cursor nobody can see.
        let wake = await DisplayWake.ensureAwake()
        guard wake != .failed else {
            throw EngineError.pathRefused("The display is asleep and could not be woken — motion over an invisible screen proves nothing.")
        }
        let hold = DisplayWake.Hold(reason: "Rocuronium is tracing a cursor path")
        defer { hold?.release() }

        var points = waypoints
        // Destination by label: resolved here so the caller can say "hover the Store tab"
        // instead of shipping coordinates. Zero-area frames are refused for the same reason
        // the reach refuses them — a closed menu item reports (0, bottom-corner) 0×0.
        if let label {
            guard let pid else {
                throw EngineError.pathRefused("A labeled destination needs --app to search in.")
            }
            let element = try resolveNamed(pid: pid, label: label, role: role, windowTitle: windowTitle)
            guard let frame = element.frame, frame.width >= 1, frame.height >= 1 else {
                throw EngineError.pathRefused("'\(label)' has no on-screen frame to move to.")
            }
            points.append(CGPoint(x: frame.midX, y: frame.midY))
        }
        // A lone destination starts from wherever the cursor is now.
        if points.count == 1, let current = CGEvent(source: nil)?.location {
            points.insert(current, at: 0)
        }
        // A bare start→end `move` gets a natural bow: human motion is never a ruler line,
        // so a slight randomized arc is injected between the endpoints. Only `move` — a
        // drag's path is semantic (sliders, selections, drawing), and bowing it would drag
        // through pixels the caller never chose; explicit --via waypoints are also left
        // exactly as given.
        if button == nil, points.count == 2 {
            points = naturallyBowed(from: points[0], to: points[1])
        }
        guard let plan = PathPlan(through: points, duration: duration, easing: easing) else {
            throw EngineError.pathRefused("The path needs two distinct points — a start (or the current cursor) and a destination at least a pixel away.")
        }

        // The point that acts is the one that must not be occluded: a drag's button lands at
        // the start, a hover's meaning lives at the end. Same rule as the reach's hardware
        // tentacle — real input goes to whatever window is topmost, and driving somebody else's
        // window with the user's cursor is the thing this tool promises not to do. The
        // measured ambush: Refrax's PIP panel silently ate a hover aimed under it.
        let actionPoint = button != nil ? plan.start : plan.end
        let ownerPid = HardwareInput.ownerOfWindow(at: actionPoint)
        var endpointOwner: String?
        if let ownerPid, ownerPid != pid {
            endpointOwner = await MainActor.run {
                NSRunningApplication(processIdentifier: ownerPid)?.localizedName ?? "pid \(ownerPid)"
            }
        }
        if let pid, let ownerPid, ownerPid != pid {
            let targetName = await MainActor.run {
                NSRunningApplication(processIdentifier: pid)?.localizedName
            }
            throw EngineError.occludedTarget(
                "'\(endpointOwner ?? "?")' covers the target app at (\(Int(actionPoint.x)), \(Int(actionPoint.y))) — the \(button != nil ? "drag" : "hover") would land on it instead. Activate or park first.",
                suggestion: "park --app \(targetName ?? "pid \(pid)")",
            )
        }

        let windowsBefore = pid.map(onScreenWindowCount)
        // What the window's tree looked like before the gesture — so the reply can say what
        // the hover revealed, not just that a window appeared. Taken before the motion, same
        // reason the window count is.
        let treeBefore = pid.flatMap { windowNodes(pid: $0, windowTitle: windowTitle) }
        // The charge-up ring at the point that acts (drag: the button-down point; hover: the
        // destination). When the overlay is visible this waits out the wind-up — the window
        // in which ⌃⌥⇧⎋ lands before any motion starts; the per-sample halt check inside the
        // trace covers everything after.
        await PresenceRelay.telegraph(actionPoint)
        let outcome = await HardwareInput.trace(plan, button: button, restoreCursor: restoreCursor)
        // Give hover-intent timers and flyout animations a beat before reading — the Steam
        // supernav opens ~120 ms after the pointer settles, and AppKit tooltips take ~1 s, so
        // `dwell` lets the caller hold longer for a tooltip. A restored cursor has already
        // left by now, so the reveal it conjured is only readable when restore is off (the
        // default — a hover means nothing once the cursor moves away).
        try? await Task.sleep(for: dwell ?? .milliseconds(400))
        let windowsAfter = pid.map(onScreenWindowCount)
        var treeChanges: Int?
        var treeDeltaText: String?
        if let pid, let treeBefore, let treeAfter = windowNodes(pid: pid, windowTitle: windowTitle) {
            let delta = TreeDelta.compute(from: treeBefore, to: treeAfter)
            if !delta.isEmpty {
                treeChanges = delta.changeCount
                treeDeltaText = TreeDelta.render(delta)
            }
        }
        if let pid { cache.invalidate(pid: pid) }

        let seconds = Double(plan.duration.components.seconds)
            + Double(plan.duration.components.attoseconds) / 1e18
        return TraceResult(
            outcome: outcome,
            plannedEnd: plan.end,
            pathLength: plan.length,
            durationSeconds: seconds,
            sampleCount: plan.samples.count,
            windowsBefore: windowsBefore,
            windowsAfter: windowsAfter,
            endpointOwner: endpointOwner,
            treeChanges: treeChanges,
            treeDelta: treeDeltaText,
        )
    }

    /// One via waypoint perpendicular to the straight line, at a randomized spot past the
    /// middle with a randomized bow of a few percent of the distance — enough that the
    /// wake reads as a hand's arc, small enough that the path never strays far from the
    /// line the caller imagined. Short hops stay straight: at 40 pt a bow is just wobble.
    private nonisolated func naturallyBowed(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length >= 40 else { return [start, end] }

        let along = Double.random(in: 0.4 ... 0.6)
        let bow = length * Double.random(in: 0.05 ... 0.12) * (Bool.random() ? 1 : -1)
        let via = CGPoint(
            x: start.x + dx * along - dy / length * bow,
            y: start.y + dy * along + dx / length * bow,
        )
        return [start, via, end]
    }

    /// On-screen windows the system attributes to this process, popup layers included —
    /// menus and flyouts often live above the normal window layer, and they are exactly
    /// what a hover conjures.
    private nonisolated func onScreenWindowCount(_ pid: pid_t) -> Int {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID,
        ) as? [[String: Any]] else { return 0 }
        return windows.count { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
    }

    // MARK: - Internals — everything below touches non-Sendable elements

    /// One key shape for every label walk, so a find-then-read-then-act chain over the same
    /// query costs one walk however the verbs are mixed.
    private nonisolated func cacheKey(_ query: String?, role: String?, window: String? = nil) -> String {
        "find:\(window ?? "*"):\(role ?? "*"):\(query ?? "*")"
    }

    /// Label to element, through the cache, with the ambiguity refusal every verb shares:
    /// acting on (or reading) whichever lookalike sorted first would be a coin flip. The
    /// refusal names each candidate's role, so the caller's next move is `role:`, not
    /// coordinates.
    private func resolveNamed(pid: pid_t, label: String, role: String? = nil, windowTitle: String? = nil) throws -> AXElement {
        if let windowTitle { _ = try windowElement(pid: pid, titled: windowTitle) }
        let matches = cache.results(for: pid, key: cacheKey(label, role: role, window: windowTitle)) {
            ElementQuery.named(label, role: role, pid: pid, windowTitle: windowTitle)
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

        case let .named(label, role, window):
            if let window { _ = try windowElement(pid: pid, titled: window) }
            let matches = ElementQuery.named(label, role: role, pid: pid, windowTitle: window).matches
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
        let title = element.title
        return ElementDescriptor(
            role: element.role,
            label: title,
            roleDescription: element.roleDescription,
            help: element.help,
            identifier: element.identifier,
            subrole: element.subrole,
            value: element.value ?? "",
            depth: depth,
            frame: element.frame.map {
                .init(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height)
            },
            // Only for the unnamed rows, and only from siblings — see the helper's note.
            near: title.isEmpty ? nearestLabelledSibling(of: element) : nil,
        )
    }

    /// The nearest labelled sibling of an unnamed element, phrased as a bearing an agent can
    /// use — "right of 'Undo'". Read from the element's siblings only (one parent fetch, its
    /// children bounded), never a tree walk, so a `find` returning twenty icon buttons stays
    /// twenty parent reads rather than twenty traversals.
    private func nearestLabelledSibling(of element: AXElement) -> String? {
        guard let frame = element.frame, let siblings = element.parent?.children else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var best: (label: String, distance: Double, dx: Double, dy: Double)?
        for sibling in siblings {
            let title = sibling.title
            guard !title.isEmpty, let siblingFrame = sibling.frame,
                  siblingFrame.width >= 1, siblingFrame.height >= 1 else { continue }
            let dx = Double(siblingFrame.midX - center.x)
            let dy = Double(siblingFrame.midY - center.y)
            let distance = hypot(dx, dy)
            if best == nil || distance < best!.distance {
                best = (title, distance, dx, dy)
            }
        }
        guard let best else { return nil }
        // The bearing is from the sibling to this element: a sibling to our right (dx > 0)
        // sits us to its left. Screen y grows downward, so a sibling above us has dy < 0.
        let direction: String
        if abs(best.dx) >= abs(best.dy) {
            direction = best.dx < 0 ? "right of" : "left of"
        } else {
            direction = best.dy < 0 ? "below" : "above"
        }
        return "\(direction) '\(best.label)'"
    }

    /// Read on this actor rather than hopping to the main one: `runningApplications` is safe to
    /// read from any thread, and a hop per find would reintroduce main-thread coupling.
    private nonisolated func livePIDs() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
    }
}
