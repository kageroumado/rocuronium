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
    }

    struct Match {
        let element: AXElement
        let depth: Int
        let path: String
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
    /// Seeded from `AXWindows` and the menu bar rather than only `AXChildren`, because the two
    /// sets differ between apps. Nested elements claiming the `AXApplication` role are not
    /// descended into: an app listing itself as its own child is a cycle that consumes the
    /// entire traversal budget before reaching any window.
    static func search(
        pid: pid_t,
        maxDepth: Int = Constants.maxDepth,
        budget: Int = Constants.elementBudget,
        where predicate: (AXElement) -> Bool
    ) -> Results {
        let root = AXElement(pid: pid)
        var matches: [Match] = []
        var visited = 0
        var seenSignatures = Set<String>()

        func visit(_ element: AXElement, depth: Int, path: String) {
            guard visited < budget, depth <= maxDepth else { return }
            visited += 1
            if predicate(element), seenSignatures.insert(element.signature).inserted {
                matches.append(Match(element: element, depth: depth, path: path))
            }
            guard depth < maxDepth else { return }
            for (index, child) in element.children.enumerated() {
                guard visited < budget else { return }
                guard child.role != "AXApplication" else { continue }
                visit(child, depth: depth + 1, path: "\(path)/\(element.role)[\(index)]")
            }
        }

        for (index, window) in root.windows.enumerated() {
            visit(window, depth: 1, path: "/win[\(index)]")
        }
        if let menuBar = root.menuBar {
            visit(menuBar, depth: 1, path: "/menubar")
        }
        for (index, child) in root.children.enumerated() where child.role != "AXApplication" {
            visit(child, depth: 1, path: "/kid[\(index)]")
        }

        return Results(
            matches: matches,
            elementsVisited: visited,
            truncated: visited >= budget,
        )
    }

    /// Every editable field in an app.
    static func editables(pid: pid_t) -> Results {
        search(pid: pid) { $0.isEditable }
    }

    /// Resolves a loose human description to candidate elements by matching against labels.
    /// Deliberately dumb: exact and substring matching only. Anything fuzzier is the vision
    /// layer's job, and pretending otherwise here would hide which component actually guessed.
    static func named(_ query: String, pid: pid_t) -> Results {
        let needle = query.lowercased()
        return search(pid: pid) { element in
            let label = element.label.lowercased()
            return !label.isEmpty && (label == needle || label.contains(needle))
        }
    }
}
