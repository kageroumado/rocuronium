import Foundation

/// A flattened, `Sendable` record of one accessibility walk, kept so a later walk of the
/// same scope can be compared against it — the mechanism behind `read --since`.
///
/// Nodes carry exactly what the diff needs (role, label, value, depth in pre-order).
/// Frames are deliberately absent: they are two extra AX round trips per element on every
/// read, the diff does not need them to decide what changed, and an agent that wants to
/// act on an appeared element resolves it with `find`, which reads the frame fresh.
nonisolated struct TreeSnapshot: Sendable {
    struct Node: Sendable, Equatable {
        let role: String
        let label: String
        let value: String
        let depth: Int
    }

    let pid: pid_t
    /// Which query produced the walk (label/role filter). A token from one scope must not
    /// diff against a walk of another — the result would be a wall of false vanishes.
    let scopeKey: String
    /// Human phrasing of what was read ("window 'Inbox'"), for degrade messages.
    let scope: String
    /// A truncated walk cannot diff honestly: elements the budget never reached would be
    /// reported as vanished.
    let truncated: Bool
    let nodes: [Node]
}

/// Structural diff between two walks of the same scope: what appeared, what vanished,
/// which values changed. Pure sequence logic, no AX — unit-testable on synthetic lists.
nonisolated enum TreeDelta {
    private enum Constants {
        /// Children listed per appeared/vanished group before "+N more".
        static let childrenShown = 10
        /// Rendered lines before "…and N more changes".
        static let linesShown = 40
        static let labelShown = 60
        static let valueShown = 120
    }

    struct ValueChange: Equatable, Sendable {
        let role: String
        let label: String
        let old: String
        let new: String
    }

    /// One appeared or vanished subtree: the topmost changed element plus its changed
    /// descendants, flattened — "a popover containing these buttons", not one line per
    /// nested group.
    struct Group: Equatable, Sendable {
        let root: TreeSnapshot.Node
        let children: [TreeSnapshot.Node]
    }

    struct Delta: Sendable {
        let appeared: [Group]
        let vanished: [Group]
        let valueChanges: [ValueChange]
        /// Changed elements as a share of the larger walk — the caller's signal that the
        /// window was replaced wholesale and a full read is the honest reply.
        let changeRatio: Double

        var changeCount: Int { appeared.count + vanished.count + valueChanges.count }
        var isEmpty: Bool { changeCount == 0 }
    }

    static func compute(from old: [TreeSnapshot.Node], to new: [TreeSnapshot.Node]) -> Delta {
        // Multiset matching on full identity (role|label|value): an element present in both
        // walks is unchanged wherever it sits. Order-insensitive on purpose — reordering
        // rows is not a change worth an agent's tokens, and pre-order positions shift
        // whenever anything above them appears.
        func identity(_ node: TreeSnapshot.Node) -> String {
            "\(node.role)\u{1}\(node.label)\u{1}\(node.value)"
        }
        var oldCounts: [String: Int] = [:]
        for node in old { oldCounts[identity(node), default: 0] += 1 }
        var added: [Int] = []
        for (index, node) in new.enumerated() {
            let key = identity(node)
            if let count = oldCounts[key], count > 0 {
                oldCounts[key] = count - 1
            } else {
                added.append(index)
            }
        }
        var newCounts: [String: Int] = [:]
        for node in new { newCounts[identity(node), default: 0] += 1 }
        var removed: [Int] = []
        for (index, node) in old.enumerated() {
            let key = identity(node)
            if let count = newCounts[key], count > 0 {
                newCounts[key] = count - 1
            } else {
                removed.append(index)
            }
        }

        // Pair leftovers that are the same control with a different value: same role and
        // label when the label names it; for label-less elements (static text), same role
        // under the same nearest labeled ancestor. Paired in walk order — beyond that
        // there is no identity to match on, and the honest degrade covers pathologies.
        let oldParents = parentIndices(of: old)
        let newParents = parentIndices(of: new)
        func pairKey(_ nodes: [TreeSnapshot.Node], _ parents: [Int?], _ index: Int) -> String {
            let node = nodes[index]
            if !node.label.isEmpty { return "\(node.role)\u{1}\(node.label)" }
            var ancestor = parents[index]
            while let a = ancestor, nodes[a].label.isEmpty { ancestor = parents[a] }
            let context = ancestor.map { "\(nodes[$0].role)|\(nodes[$0].label)" } ?? ""
            return "\(node.role)\u{1}\u{2}\(context)"
        }
        var removedByKey: [String: [Int]] = [:]
        for index in removed { removedByKey[pairKey(old, oldParents, index), default: []].append(index) }
        var valueChanges: [ValueChange] = []
        var pairedNew = Set<Int>()
        var pairedOld = Set<Int>()
        for index in added {
            let key = pairKey(new, newParents, index)
            guard var candidates = removedByKey[key], !candidates.isEmpty else { continue }
            let oldIndex = candidates.removeFirst()
            removedByKey[key] = candidates
            // Equal values can both be leftover when only multiplicity changed; that is an
            // appearance, not a value change.
            guard old[oldIndex].value != new[index].value else {
                removedByKey[key, default: []].insert(oldIndex, at: 0)
                continue
            }
            valueChanges.append(ValueChange(
                role: new[index].role,
                label: new[index].label,
                old: old[oldIndex].value,
                new: new[index].value,
            ))
            pairedNew.insert(index)
            pairedOld.insert(oldIndex)
        }
        let appearedIndices = added.filter { !pairedNew.contains($0) }
        let vanishedIndices = removed.filter { !pairedOld.contains($0) }

        let changed = appearedIndices.count + vanishedIndices.count + valueChanges.count
        let ratio = Double(changed) / Double(max(old.count, new.count, 1))
        return Delta(
            appeared: groups(for: appearedIndices, in: new, parents: newParents),
            vanished: groups(for: vanishedIndices, in: old, parents: oldParents),
            valueChanges: valueChanges,
            changeRatio: ratio,
        )
    }

    /// Pre-order parent links: the nearest preceding node with a smaller depth.
    private static func parentIndices(of nodes: [TreeSnapshot.Node]) -> [Int?] {
        var parents = [Int?](repeating: nil, count: nodes.count)
        var stack: [Int] = []
        for (index, node) in nodes.enumerated() {
            while let top = stack.last, nodes[top].depth >= node.depth { stack.removeLast() }
            parents[index] = stack.last
            stack.append(index)
        }
        return parents
    }

    /// Groups changed elements under their topmost changed ancestor, so a popover
    /// appearing reads as one popover with its contents, not one line per descendant.
    private static func groups(
        for indices: [Int], in nodes: [TreeSnapshot.Node], parents: [Int?]
    ) -> [Group] {
        let changed = Set(indices)
        var rootOf: [Int: Int] = [:]
        for index in indices {
            var topmost = index
            var ancestor = parents[index]
            while let a = ancestor {
                if changed.contains(a) { topmost = a }
                ancestor = parents[a]
            }
            rootOf[index] = topmost
        }
        var childrenOf: [Int: [Int]] = [:]
        for index in indices where rootOf[index] != index {
            childrenOf[rootOf[index]!, default: []].append(index)
        }
        return indices
            .filter { rootOf[$0] == $0 }
            .map { root in
                Group(root: nodes[root], children: (childrenOf[root] ?? []).map { nodes[$0] })
            }
    }

    // MARK: - Rendering

    /// The compact text the reply carries — the whole point of the verb: an agent pays for
    /// these lines instead of the frame.
    static func render(_ delta: Delta) -> String {
        guard !delta.isEmpty else { return "no changes" }
        var lines: [String] = []
        for group in delta.appeared { lines.append(line("appeared", group)) }
        for group in delta.vanished { lines.append(line("vanished", group)) }
        for change in delta.valueChanges {
            let name = change.label.isEmpty ? change.role : "\(change.role) '\(clip(change.label, Constants.labelShown))'"
            lines.append("value changed: \(name): '\(clip(change.old, Constants.valueShown))' → '\(clip(change.new, Constants.valueShown))'")
        }
        if lines.count > Constants.linesShown {
            let hidden = lines.count - Constants.linesShown
            lines = Array(lines.prefix(Constants.linesShown))
            lines.append("…and \(hidden) more change(s)")
        }
        return lines.joined(separator: "\n")
    }

    private static func line(_ verb: String, _ group: Group) -> String {
        guard !group.children.isEmpty else { return "\(verb): \(describe(group.root))" }
        var shown = group.children.prefix(Constants.childrenShown).map(describe)
        if group.children.count > Constants.childrenShown {
            shown.append("+\(group.children.count - Constants.childrenShown) more")
        }
        return "\(verb): \(describe(group.root)) containing [\(shown.joined(separator: ", "))]"
    }

    private static func describe(_ node: TreeSnapshot.Node) -> String {
        let label = node.label.isEmpty ? nil : clip(node.label, Constants.labelShown)
        let value = node.value.isEmpty ? nil : clip(node.value, Constants.valueShown)
        switch (label, value) {
        case let (label?, value?) where label != value: return "\(node.role) '\(label)' = '\(value)'"
        case let (label?, _): return "\(node.role) '\(label)'"
        case let (nil, value?): return "\(node.role) '\(value)'"
        default: return node.role
        }
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : text.prefix(limit) + "…"
    }
}

/// Holds the recent walks `read` replies handed out tokens for, so `--since` has
/// something to diff against. Owned exclusively by `Engine`, like `TreeCache`, so it
/// needs no isolation of its own.
nonisolated final class TreeSnapshotStore {
    private enum Constants {
        /// Snapshots kept per process. An agent diffing a window needs the one it last
        /// saw, occasionally two; more is memory spent on walks nobody will name again.
        static let perProcessCap = 3
        static let totalCap = 12
    }

    private var snapshots: [String: TreeSnapshot] = [:]
    /// Insertion/use order, oldest first — the eviction order.
    private var order: [String] = []

    /// Stores a walk and returns its observation token.
    func store(_ snapshot: TreeSnapshot) -> String {
        let token = "ax\(snapshot.pid)-\(UUID().uuidString.prefix(8).lowercased())"
        snapshots[token] = snapshot
        order.append(token)

        let sameProcess = order.filter { snapshots[$0]?.pid == snapshot.pid }
        if sameProcess.count > Constants.perProcessCap {
            evict(sameProcess.first!)
        }
        while order.count > Constants.totalCap {
            evict(order.first!)
        }
        return token
    }

    /// The walk a token names, if it has not been evicted. Reading refreshes its LRU spot:
    /// a token being diffed against is a token about to be replaced by its successor.
    func snapshot(for token: String) -> TreeSnapshot? {
        guard let snapshot = snapshots[token] else { return nil }
        if let index = order.firstIndex(of: token) {
            order.remove(at: index)
            order.append(token)
        }
        return snapshot
    }

    /// Same hygiene as `TreeCache`: a dead process's walk must never diff against
    /// whatever inherits its pid.
    func evictDeadProcesses(livePIDs: Set<pid_t>) {
        for token in order where !livePIDs.contains(snapshots[token]?.pid ?? -1) {
            evict(token)
        }
    }

    private func evict(_ token: String) {
        snapshots[token] = nil
        if let index = order.firstIndex(of: token) { order.remove(at: index) }
    }
}
