import CoreGraphics
import Foundation

/// The scroll areas of a window, and which one a scroll without a label means.
///
/// A window commonly has several — a sidebar, a content pane, an inspector — and taking the
/// first in tree order scrolled the sidebar when the caller meant the pane (the Sevoflurane
/// Settings walk, 2026-09-20). Without `--label` or `--area`, the pick is the **largest area that
/// can scroll** (it exposes a vertical scroll bar with a position), else the largest area at
/// all, and the reply names which one of how many it took, so `--area <n>` can redirect it.
nonisolated enum ScrollAreas {
    private enum Constants {
        static let searchDepth = 20
        static let searchBudget = 3000
    }

    /// One area as the chooser sees it.
    struct Candidate: Sendable {
        let frame: CGRect?
        /// It exposes a vertical scroll bar with a numeric position.
        let scrollable: Bool
    }

    enum Choice: Equatable, Sendable {
        case none
        case index(Int)
        /// `--area` named an index past the end.
        case outOfRange(count: Int)
    }

    /// Which candidate a scroll aims at: `requested` when given, else the largest scrollable,
    /// else the largest. Pure, for the tests.
    static func choose(_ candidates: [Candidate], requested: Int?) -> Choice {
        guard !candidates.isEmpty else { return requested == nil ? .none : .outOfRange(count: 0) }
        if let requested {
            return candidates.indices.contains(requested) ? .index(requested) : .outOfRange(count: candidates.count)
        }
        func area(_ index: Int) -> CGFloat {
            guard let frame = candidates[index].frame else { return 0 }
            return frame.width * frame.height
        }
        let scrollable = candidates.indices.filter { candidates[$0].scrollable }
        let pool = scrollable.isEmpty ? Array(candidates.indices) : scrollable
        // `max` keeps the first of equals, so ties go to tree order.
        return .index(pool.max { area($0) < area($1) }!)
    }

    /// Every `AXScrollArea` under `root` in tree order, nested ones included.
    static func all(under root: AXElement) -> [AXElement] {
        var found: [AXElement] = []
        var visited = 0
        func visit(_ element: AXElement, depth: Int) {
            guard depth <= Constants.searchDepth, visited < Constants.searchBudget, !Task.isCancelled else { return }
            visited += 1
            if element.role == "AXScrollArea" { found.append(element) }
            for child in element.children {
                guard visited < Constants.searchBudget else { return }
                guard child.role != "AXApplication" else { continue }
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return found
    }
}
