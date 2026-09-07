import ApplicationServices
import Foundation

/// Finding elements in an app, cheapest strategy first.
///
/// The expensive strategy — walking the whole tree — is the fallback, not the default. Two
/// measured facts shape this type:
///
/// - Electron composer fields sit **23 levels deep** in a 5,320-element tree. A 12-level cap
///   looks reasonable and silently hides them, producing the false conclusion that the app
///   exposes nothing. Depth defaults to 40 and truncation is always reported.
/// - The focused-element query is instant and finds elements a walk misses, so it is tried
///   before any traversal.
nonisolated enum ElementQuery {
    enum Constants {
        /// Deep enough for Chromium DOM trees; see the depth-23 measurement.
        static let maxDepth = 40
        /// Discord's full tree is ~5,300 elements and takes ~1.2 s. The budget is a runaway
        /// guard, not a target.
        static let elementBudget = 60_000
        /// Wall-clock bound on a walk. The element budget bounds memory, not time — each
        /// element costs several AX IPC round trips, and Finder with a desktop full of icons
        /// blew past the control socket's 30 s on a walk well inside the element budget.
        /// Truncated results before the socket gives up beat complete results after.
        static let timeBudget: Duration = .seconds(18)
    }

    struct Match {
        let element: AXElement
        let depth: Int
    }

    struct Results {
        let matches: [Match]
        let elementsVisited: Int
        /// True when the budget or depth limit cut the search short. Callers must surface this:
        /// "nothing found" and "stopped looking" are different answers.
        let truncated: Bool
    }

    // MARK: - Cheap strategies

    /// What the app itself considers focused. O(1), and the most reliable single probe for
    /// Electron and other apps whose trees under-report.
    static func focused(pid: pid_t) -> AXElement? {
        AXElement(pid: pid).focused
    }

    /// Hit-test a screen point. O(1) and toolkit-independent — the right way to resolve a
    /// coordinate the vision layer produced into a real element.
    static func hitTest(_ point: CGPoint, pid: pid_t) -> AXElement? {
        var out: AXUIElement?
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &out) == .success,
              let out
        else { return nil }
        return AXElement(out)
    }

    // MARK: - Full traversal

    /// Walks an app's tree, collecting elements that satisfy `predicate`.
    ///
    /// Seeded from `AXWindows` plus the non-window `AXChildren` (the two sets differ between
    /// apps). Nested elements claiming the `AXApplication` role are not descended into: an app
    /// listing itself as its own child is a cycle that consumes the entire traversal budget
    /// before reaching any window.
    ///
    /// The **menu bar is deliberately not walked**. Menu items are the right match for
    /// nothing except `menu`/`shortcut`, which have their own resolution (`MenuQuery`) — and
    /// a closed menu item reports a meaningless 0×0 frame at the screen corner, so acting on
    /// one through `click`/`scroll` aims at geometry that does not exist. Measured
    /// 2026-08-09: `wait --label References` on Safari matched a History-menu entry whose
    /// *title* contained "references", a false positive that then poisoned a scroll probe
    /// (its "scroll area" ascended from the menu item).
    /// The windows a `WindowSelector` names, among the real window roles — the seed set for a
    /// window-scoped search. A title substring filters by title (case-insensitive); `at`
    /// keeps only windows whose frame contains the point; `index` then picks one by 0-based
    /// position in what remains. Empty when nothing matches, so the caller can tell "no such
    /// window" from "the app has no windows".
    static func windows(pid: pid_t, selector: WindowSelector) -> [AXElement] {
        let windowRoles = ["AXWindow", "AXSheet", "AXDialog", "AXDrawer"]
        var candidates = AXElement(pid: pid).windows.filter { windowRoles.contains($0.role) }
        if let needle = selector.title?.lowercased() {
            candidates = candidates.filter {
                ($0.string(kAXTitleAttribute) ?? "").lowercased().contains(needle)
            }
        }
        if let point = selector.at {
            candidates = candidates.filter { $0.frame?.contains(point) == true }
        }
        if let index = selector.index {
            candidates = (index >= 0 && index < candidates.count) ? [candidates[index]] : []
        }
        return candidates
    }

    static func search(
        pid: pid_t,
        window: WindowSelector = .init(),
        maxDepth: Int = Constants.maxDepth,
        budget: Int = Constants.elementBudget,
        where predicate: (AXElement) -> Bool
    ) -> Results {
        let root = AXElement(pid: pid)
        var matches: [Match] = []
        var visited = 0
        var seenSignatures = Set<String>()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Constants.timeBudget)
        var outOfTime = false

        func visit(_ element: AXElement, depth: Int) {
            guard visited < budget, depth <= maxDepth, !outOfTime else { return }
            // Both stops matter and they are different: the deadline keeps this walk inside
            // the socket's reply window, and the cancellation check stops a walk whose caller
            // has already been told "timed out" — without it the walk keeps burning the
            // engine actor, and every queued request behind it times out too (measured: two
            // abandoned Finder walks poisoned the socket for a full minute).
            if Task.isCancelled || EmergencyStop.isHalted || clock.now >= deadline {
                outOfTime = true
                return
            }
            visited += 1
            if predicate(element), seenSignatures.insert(element.signature).inserted {
                matches.append(Match(element: element, depth: depth))
            }
            guard depth < maxDepth else { return }
            for child in element.children {
                guard visited < budget, !outOfTime else { return }
                guard child.role != "AXApplication" else { continue }
                visit(child, depth: depth + 1)
            }
        }

        // Window scope, when asked: seed from only the matching windows, and skip the
        // non-window children entirely — a `--window` query means "inside this window", not
        // "this window plus whatever floats beside it".
        if window.isSpecified {
            for windowElement in windows(pid: pid, selector: window) {
                visit(windowElement, depth: 1)
            }
        } else {
            for window in root.windows {
                visit(window, depth: 1)
            }
            // The menu bar arrives through `AXChildren` too, so it is skipped here as well —
            // see the type comment for why menus are excluded from label walks entirely.
            for child in root.children
                where child.role != "AXApplication" && child.role != "AXMenuBar" {
                visit(child, depth: 1)
            }
        }

        return Results(
            matches: matches,
            elementsVisited: visited,
            truncated: visited >= budget || outOfTime,
        )
    }

    /// Every editable field in an app, or in one window when scoped.
    static func editables(pid: pid_t, window: WindowSelector = .init()) -> Results {
        search(pid: pid, window: window) { $0.isEditable }
    }

    /// Resolves a loose human description to candidate elements. Deliberately dumb: exact and
    /// substring matching only. Anything fuzzier is the vision layer's job, and pretending
    /// otherwise here would hide which component actually guessed.
    ///
    /// Labels first, values as the fallback — in one walk. The text an agent sees in `read`
    /// output is often a *value* (note bodies, static text), and a label-only match made that
    /// text unfindable and un-scrollable-to. But values are noisy — a query like "save" sits
    /// inside any document mentioning saving — so a value match never competes with a label
    /// match: it is used only when no label matched at all.
    ///
    /// `role` narrows by element role when several roles share a label (a button and a menu
    /// item both titled "Restart to update" — measured on Refrax). "button" and "AXButton"
    /// both work; matching is case-insensitive.
    static func named(_ query: String, role: String? = nil, pid: pid_t, window: WindowSelector = .init()) -> Results {
        let needle = query.lowercased()
        func labelMatches(_ element: AXElement) -> Bool {
            let label = element.label.lowercased()
            return !label.isEmpty && (label == needle || label.contains(needle))
        }
        let results = search(pid: pid, window: window) { element in
            guard roleMatches(element.role, wanted: role) else { return false }
            return labelMatches(element) || element.value?.lowercased().contains(needle) == true
        }
        // Re-reading the label here costs one IPC round trip per *match* (bounded and small),
        // not per element visited — the price of distinguishing the two tiers in a single walk.
        let labelTier = results.matches.filter { labelMatches($0.element) }
        return Results(
            matches: labelTier.isEmpty ? results.matches : labelTier,
            elementsVisited: results.elementsVisited,
            truncated: results.truncated,
        )
    }

    /// Role comparison for the `role` filter: nil matches everything, and the "AX" prefix is
    /// optional because nobody types it.
    static func roleMatches(_ role: String, wanted: String?) -> Bool {
        guard let wanted else { return true }
        let have = role.lowercased()
        let want = wanted.lowercased()
        return have == want || have == "ax" + want
    }
}
