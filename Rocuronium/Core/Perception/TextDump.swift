import ApplicationServices
import Foundation

/// Collects the readable text of a subtree: static text, field values, button titles,
/// checked states.
///
/// This is the observe-side counterpart of the ghost reach — for text-shaped questions it is
/// orders of magnitude cheaper in tokens than a screenshot, and it works while the screen is
/// locked (though not while the display sleeps; callers guard with `DisplayWake` first).
///
/// The walk is bounded the way `MenuQuery` bounds its own: the element budget gates **every
/// child visit**, not just recursion entry, so one pathologically wide container cannot spend
/// the whole budget on a single level. A character budget bounds the other axis — a tree of
/// modest size can still carry entire documents in its values.
nonisolated enum TextDump {
    enum Constants {
        /// Same measured depth rule as `ElementQuery`: Discord's composer sits at depth 23,
        /// so a cautious-looking cap silently hides real content.
        static let maxDepth = 40
        /// Each visited element costs several AX IPC round trips (role, title, value,
        /// children), so this bounds latency as much as memory.
        static let elementBudget = 20_000
        /// Total characters across all lines. Generous for any real window of prose; the cap
        /// exists because a single web view or editor can expose a book.
        static let characterBudget = 30_000
        /// One element's value can be an entire document. Longer values are cut and marked,
        /// so one editor buffer cannot spend the whole character budget by itself.
        static let valueCharacterCap = 4_000
        /// Wall-clock bound, for the same reason `ElementQuery` has one: elements are not
        /// time, and the socket's 30 s reply window is the real ceiling.
        static let timeBudget: Duration = .seconds(18)
    }

    struct Line {
        let role: String
        /// The element's own name: title, description, or placeholder. Never the role
        /// description — for static text that is the literal word "text", which would bury
        /// the dump in noise.
        let title: String
        /// The element's value: field contents, static text, or a checkbox's "0"/"1".
        let value: String
        let depth: Int
    }

    struct Results {
        let lines: [Line]
        let elementsVisited: Int
        let characters: Int
        let truncated: Bool
        /// Which cap cut the walk short, when one did. "Nothing found" and "stopped looking"
        /// are different answers, and the caller must be able to tell them apart.
        let truncationReason: String?
        /// An `AXWebArea` whose subtree yielded no text. WebKit exposes nothing for its web
        /// content while returning success codes, so reporting the page as empty would be a
        /// lie — the caller turns this into a referral naming the channel that can read it.
        let silentWebArea: AXElement?
        /// Every visited element, text-less containers included — the record `read --since`
        /// diffs against. Containers matter even though `lines` skips them: an appeared
        /// popover is the ancestor its appeared buttons get grouped under. Costs nothing
        /// extra: every field here was already read for `lines`.
        let nodes: [TreeSnapshot.Node]
    }

    static func dump(root: AXElement) -> Results {
        var lines: [Line] = []
        var nodes: [TreeSnapshot.Node] = []
        var visited = 0
        var characters = 0
        var truncationReason: String?
        var silentWebArea: AXElement?
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Constants.timeBudget)

        func visit(_ element: AXElement, depth: Int) {
            // Cancellation stops a walk whose caller was already told "timed out" — an
            // abandoned walk otherwise keeps the engine actor busy and every queued request
            // behind it times out too.
            if Task.isCancelled || EmergencyStop.isHalted || clock.now >= deadline {
                truncationReason = EmergencyStop.isHalted ? "halted by the human (⌃⌥⇧⎋)" : "time budget reached"
                return
            }
            visited += 1
            let role = element.role

            var title = ""
            for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
                if let value = element.string(name), !value.isEmpty { title = value; break }
            }
            var value = element.value ?? ""
            if value.count > Constants.valueCharacterCap {
                value = String(value.prefix(Constants.valueCharacterCap)) + " […cut]"
            }
            // Snapshotted before the title==value blanking below: that blanking is display
            // economy, and letting it into the snapshot would flip an element's identity
            // whenever its value drifts into or out of equality with its title.
            nodes.append(.init(role: role, label: title, value: value, depth: depth))
            // A title that merely repeats the value carries no information, only tokens.
            if title == value { title = "" }
            if !title.isEmpty || !value.isEmpty {
                lines.append(Line(role: role, title: title, value: value, depth: depth))
                characters += title.count + value.count
                guard characters < Constants.characterBudget else {
                    truncationReason = "character budget (\(Constants.characterBudget)) reached"
                    return
                }
            }

            guard depth < Constants.maxDepth else {
                // Whether anything was hidden is knowable for one extra read, and worth it:
                // this is exactly the silent-depth-cap trap the depth-23 measurement exposed.
                if truncationReason == nil, !element.children.isEmpty {
                    truncationReason = "depth cap (\(Constants.maxDepth)) reached with children below"
                }
                return
            }
            let linesBefore = lines.count
            for child in element.children {
                // The budget gates every child, not just recursion entry — one wide
                // container must not be walked in full once the budget is spent.
                guard visited < Constants.elementBudget else {
                    truncationReason = "element budget (\(Constants.elementBudget)) reached"
                    return
                }
                guard truncationReason == nil else { return }
                guard child.role != "AXApplication" else { continue }
                visit(child, depth: depth + 1)
            }
            // A web area that contributed nothing below itself is WebKit hiding its content,
            // not an empty page.
            if role == "AXWebArea", lines.count == linesBefore, silentWebArea == nil {
                silentWebArea = element
            }
        }

        // A wedged-but-awake app answers no AX query: every read below would time out to empty,
        // producing lines: [] with truncated: false — indistinguishable from an app with no text.
        // Probe once and report the busy app instead.
        guard root.isResponding else {
            return Results(
                lines: [], elementsVisited: 0, characters: 0, truncated: true,
                truncationReason: "the app did not answer accessibility queries (2s timeout) — it may be busy or wedged",
                silentWebArea: nil, nodes: [],
            )
        }

        visit(root, depth: 0)
        return Results(
            lines: lines,
            elementsVisited: visited,
            characters: characters,
            truncated: truncationReason != nil,
            truncationReason: truncationReason,
            silentWebArea: silentWebArea,
            nodes: nodes,
        )
    }
}
