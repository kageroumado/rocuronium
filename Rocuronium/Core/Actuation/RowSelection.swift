import AppKit
import ApplicationServices

/// A click on a list row, delivered the way the row accepts it: by selecting it.
///
/// A SwiftUI `List` sidebar row (an `AXRow` in an `AXOutline` or `AXTable`) exposes no press
/// action, and a posted click at its point reads "ok" while the selection — and the pane it
/// drives — stays put (measured on Sevoflurane's Settings, 2026-09-20: `click --label Graphics`).
/// Writing the container's `AXSelectedRows` selects it. So for a press-less element inside a
/// row, the click is that write — the container's `AXSelectedRows`, else the row's own
/// `AXSelected` — confirmed only when the selection reads back with the row in it. Ghost: no
/// cursor, no focus.
nonisolated enum RowSelection {
    private enum Constants {
        /// A row's text sits a cell or two below the row.
        static let ascentLimit = 4
        /// Long enough for SwiftUI to push the binding back into the tree.
        static let settle: Duration = .milliseconds(200)
    }

    static let containerRoles: Set<String> = ["AXOutline", "AXTable", "AXList"]

    /// Selects the row `element` is or sits in, when it has no press action of its own.
    /// Nil when this is not a press-less row element, or when neither write took — the
    /// ordinary ladder then runs, as it would have.
    static func click(_ element: AXElement, pid: pid_t) async -> Evidence? {
        guard element.pressishAction == nil, let row = enclosingRow(of: element) else { return nil }
        let container = row.parent.flatMap { containerRoles.contains($0.role) ? $0 : nil }
        let target = "AXRow '\(rowName(row, fallback: element))'"
        let cursorBefore = EventPoster.cursorLocation
        let frontBefore = await MainActor.run { EventPoster.frontmostBundleID }
        var attempts: [Evidence.Attempt] = []

        if isSelected(row, in: container) {
            attempts.append(.init(tentacle: .accessibility, outcome: "the row is already selected"))
            return await evidence(target, .confirmed, "row already selected", attempts, cursorBefore, frontBefore, pid)
        }
        if let container {
            let code = container.setAttribute(kAXSelectedRowsAttribute, [row.raw] as CFArray)
            try? await Task.sleep(for: Constants.settle)
            if isSelected(row, in: container) {
                attempts.append(.init(tentacle: .accessibility, outcome: "\(container.role) AXSelectedRows written; the selection reads back with the row in it"))
                return await evidence(target, .confirmed, "row selected", attempts, cursorBefore, frontBefore, pid)
            }
            attempts.append(.init(
                tentacle: .accessibility,
                outcome: code == .success
                    ? "AXSelectedRows write reported success; the selection did not change"
                    : "AXSelectedRows write failed: \(GhostReach.phrase(for: code))",
            ))
        }
        row.setBool(true, for: kAXSelectedAttribute)
        try? await Task.sleep(for: Constants.settle)
        if isSelected(row, in: container) {
            attempts.append(.init(tentacle: .accessibility, outcome: "AXSelected written on the row; it reads back selected"))
            return await evidence(target, .confirmed, "row selected", attempts, cursorBefore, frontBefore, pid)
        }
        // Neither write took: the ladder runs as it would have. Its own attempts are what the
        // reply reports, so these are dropped rather than half-merged.
        return nil
    }

    /// The `AXRow` that is `element` or one of its near ancestors; nil past a window.
    static func enclosingRow(of element: AXElement) -> AXElement? {
        var current: AXElement? = element
        for _ in 0 ... Constants.ascentLimit {
            guard let node = current else { return nil }
            let role = node.role
            if role == "AXRow" { return node }
            if ["AXWindow", "AXSheet", "AXApplication"].contains(role) || containerRoles.contains(role) { return nil }
            current = node.parent
        }
        return nil
    }

    /// Selected per the container's `AXSelectedRows` when it has one, else the row's own flag.
    private static func isSelected(_ row: AXElement, in container: AXElement?) -> Bool {
        if let container, let rows = container.attribute(kAXSelectedRowsAttribute) as? [AXUIElement] {
            return rows.contains { CFEqual($0, row.raw) }
        }
        return row.boolValue(kAXSelectedAttribute) == true
    }

    /// What the row says: its own name, else its first static text, else the clicked element's.
    private static func rowName(_ row: AXElement, fallback: AXElement) -> String {
        if !row.title.isEmpty { return row.title }
        var queue = row.children
        var visited = 0
        while !queue.isEmpty, visited < 24 {
            let node = queue.removeFirst()
            visited += 1
            if node.role == "AXStaticText", let text = node.value, !text.isEmpty { return text }
            queue.append(contentsOf: node.children)
        }
        return fallback.title.isEmpty ? (fallback.value ?? "") : fallback.title
    }

    private static func evidence(
        _ target: String, _ verdict: Evidence.Verdict, _ readback: String,
        _ attempts: [Evidence.Attempt], _ cursorBefore: CGPoint, _ frontBefore: String, _ pid: pid_t
    ) async -> Evidence {
        let cursorAfter = EventPoster.cursorLocation
        let frontAfter = await MainActor.run { EventPoster.frontmostBundleID }
        let targetBundle = await MainActor.run { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
        return Evidence(
            action: "click", target: target, tentacle: .accessibility, verdict: verdict,
            readback: readback, pixelDelta: nil, focusBefore: nil, focusAfter: nil,
            cursorMoved: hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y) >= 1,
            frontmostChanged: frontAfter != frontBefore,
            frontmostBecameTarget: frontAfter != frontBefore && frontAfter == targetBundle,
            attempts: attempts, referral: nil,
        )
    }
}
