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
        /// How the element answered a `--label` query; nil for role and predicate searches.
        var classification: LabelMatching.Classification? = nil
    }

    struct Results {
        let matches: [Match]
        let elementsVisited: Int
        /// True when the budget or depth limit cut the search short. Callers must surface this:
        /// "nothing found" and "stopped looking" are different answers.
        let truncated: Bool
        /// Which limit cut the walk short, when one did — mirroring `TextDump.truncationReason`.
        /// "You halted me", "too many elements — narrow", and "the app is slow" are different
        /// answers, and a truncated `find` is only actionable when the caller can tell them apart.
        let truncationReason: String?
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
    static func search(
        pid: pid_t,
        window: WindowSelector = .init(),
        maxDepth: Int = Constants.maxDepth,
        budget: Int = Constants.elementBudget,
        where predicate: (AXElement) -> Bool
    ) -> Results {
        let root = AXElement(pid: pid)
        // A wedged-but-awake app answers no AX query, and every read below would time out to nil,
        // producing an empty, untruncated result indistinguishable from an app that genuinely
        // exposes nothing. Probe the root once and say which it is.
        guard root.isResponding else {
            return Results(
                matches: [], elementsVisited: 0, truncated: true,
                truncationReason: "the app did not answer accessibility queries (2s timeout) — it may be busy or wedged",
            )
        }
        var matches: [Match] = []
        var visited = 0
        var seenSignatures = Set<String>()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Constants.timeBudget)
        var outOfTime = false
        var truncationReason: String?

        func visit(_ element: AXElement, depth: Int) {
            guard !outOfTime else { return }
            // These stops are different answers and the caller acts on which one fired: the
            // deadline keeps this walk inside the socket's reply window, and the cancellation
            // check stops a walk whose caller has already been told "timed out" — without it
            // the walk keeps burning the engine actor, and every queued request behind it
            // times out too (measured: two abandoned Finder walks poisoned the socket for a
            // full minute).
            if Task.isCancelled || EmergencyStop.isHalted || clock.now >= deadline {
                if truncationReason == nil {
                    truncationReason = EmergencyStop.isHalted
                        ? "halted by the human (⌃⌥⇧⎋)"
                        : (Task.isCancelled ? "the request was cancelled" : "time budget reached")
                }
                outOfTime = true
                return
            }
            guard visited < budget else {
                truncationReason = truncationReason ?? "element budget (\(budget)) reached — narrow the search"
                outOfTime = true
                return
            }
            guard depth <= maxDepth else { return }
            visited += 1
            if predicate(element), seenSignatures.insert(element.signature).inserted {
                matches.append(Match(element: element, depth: depth))
            }
            guard depth < maxDepth else {
                // Whether anything was hidden below is one extra read and worth it: this is the
                // silent-depth-cap trap the depth-23 measurement exposed.
                if truncationReason == nil, !element.children.isEmpty {
                    truncationReason = "depth cap (\(maxDepth)) reached with children below"
                }
                return
            }
            for child in element.children {
                guard !outOfTime else { return }
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
            truncated: truncationReason != nil,
            truncationReason: truncationReason,
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
    /// match: it is used only when no label matched at all. `LabelMatching` holds the rules.
    ///
    /// A control with no name of its own is matched by the label its row gives it
    /// (`AXElement.derivedLabel`), and the static text that label was read from is dropped from
    /// the matches when the control is among them: they are one target, and the control is the
    /// one that acts.
    ///
    /// `exact` keeps whole-string matches only. `role` narrows by element role when several
    /// roles share a label (a button and a menu item both titled "Restart to update" —
    /// measured on Refrax). "button" and "AXButton" both work; matching is case-insensitive.
    static func named(
        _ query: String, role: String? = nil, pid: pid_t, window: WindowSelector = .init(), exact: Bool = false
    ) -> Results {
        func names(_ element: AXElement) -> (names: [String], derived: DerivedLabel?) {
            let derived = element.derivedLabel
            return ([element.label] + (derived.map { [$0.text] } ?? []), derived)
        }
        func classify(_ element: AXElement) -> (LabelMatching.Classification?, DerivedLabel?) {
            let (candidates, derived) = names(element)
            return (LabelMatching.classify(names: candidates, value: element.value, needle: query, exactOnly: exact), derived)
        }
        let results = search(pid: pid, window: window) { element in
            guard roleMatches(element.role, wanted: role) else { return false }
            return classify(element).0 != nil
        }
        // Re-classifying here costs a few IPC round trips per *match* (bounded and small), not
        // per element visited — the price of keeping the walk's predicate a plain Bool.
        var derivedSources = Set<String>()
        var classified: [Match] = results.matches.map { match in
            let (classification, derived) = classify(match.element)
            if let source = derived?.sourceSignature { derivedSources.insert(source) }
            var copy = match
            copy.classification = classification
            return copy
        }
        if !derivedSources.isEmpty {
            classified.removeAll { derivedSources.contains($0.element.signature) }
        }
        let tier = LabelMatching.tier(classified.map(\.classification))
        return Results(
            matches: tier.map { classified[$0] },
            elementsVisited: results.elementsVisited,
            truncated: results.truncated,
            truncationReason: results.truncationReason,
        )
    }

    /// One target out of a label search's matches, with the rule that chose it, or the
    /// ambiguity. In `exact` mode every survivor already matched whole, so a single one is
    /// reported as `exact`.
    static func pickOne(_ matches: [Match], exact: Bool) -> (match: Match?, matchedBy: String?, ambiguous: [Match]) {
        switch LabelMatching.pick(matches.map(\.classification)) {
        case .none:
            return (nil, nil, [])
        case let .one(index, matchedBy):
            return (matches[index], exact ? LabelMatching.MatchedBy.exact.rawValue : matchedBy.rawValue, [])
        case let .ambiguous(indices):
            return (nil, nil, indices.map { matches[$0] })
        }
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
