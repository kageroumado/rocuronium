import Darwin
import Testing
@testable import Rocuronium

/// The structural differ behind `read --since`, exercised on synthetic walks — no AX, no
/// app host behavior.
struct TreeDeltaTests {
    private func node(
        _ role: String, _ label: String = "", value: String = "", depth: Int = 1
    ) -> TreeSnapshot.Node {
        TreeSnapshot.Node(role: role, label: label, value: value, depth: depth)
    }

    private var window: [TreeSnapshot.Node] {
        [
            node("AXWindow", "Inbox", depth: 0),
            node("AXButton", "Reply"),
            node("AXStaticText", value: "3 unread"),
            node("AXTextField", "Search", value: "cat"),
        ]
    }

    @Test func identicalWalksReportNoChanges() {
        let delta = TreeDelta.compute(from: window, to: window)
        #expect(delta.isEmpty)
        #expect(TreeDelta.render(delta) == "no changes")
        #expect(delta.changeRatio == 0)
    }

    @Test func appearedElementIsReported() {
        var new = window
        new.append(node("AXButton", "Archive"))
        let delta = TreeDelta.compute(from: window, to: new)
        #expect(delta.appeared.count == 1)
        #expect(delta.appeared.first?.root.label == "Archive")
        #expect(delta.vanished.isEmpty)
        #expect(delta.valueChanges.isEmpty)
        #expect(TreeDelta.render(delta) == "appeared: AXButton 'Archive'")
    }

    @Test func vanishedElementIsReported() {
        var new = window
        new.remove(at: 1)
        let delta = TreeDelta.compute(from: window, to: new)
        #expect(delta.vanished.count == 1)
        #expect(delta.appeared.isEmpty)
        #expect(TreeDelta.render(delta) == "vanished: AXButton 'Reply'")
    }

    @Test func valueChangeIsPairedNotAppearVanish() {
        var new = window
        new[3] = node("AXTextField", "Search", value: "caterpillar")
        let delta = TreeDelta.compute(from: window, to: new)
        #expect(delta.appeared.isEmpty)
        #expect(delta.vanished.isEmpty)
        #expect(delta.valueChanges == [
            .init(role: "AXTextField", label: "Search", old: "cat", new: "caterpillar"),
        ])
        #expect(TreeDelta.render(delta) == "value changed: AXTextField 'Search': 'cat' → 'caterpillar'")
    }

    /// Label-less elements (static text) pair through their nearest labeled ancestor, so a
    /// status line rewriting itself reads as one value change, not a vanish plus an appear.
    @Test func labelLessValueChangePairsByAncestor() {
        var new = window
        new[2] = node("AXStaticText", value: "no unread")
        let delta = TreeDelta.compute(from: window, to: new)
        #expect(delta.appeared.isEmpty)
        #expect(delta.vanished.isEmpty)
        #expect(delta.valueChanges == [
            .init(role: "AXStaticText", label: "", old: "3 unread", new: "no unread"),
        ])
        #expect(TreeDelta.render(delta) == "value changed: AXStaticText: '3 unread' → 'no unread'")
    }

    /// The grouping the verb exists for: a popover and its buttons come back as one line,
    /// descendants flattened under the topmost appeared ancestor.
    @Test func appearedSubtreeGroupsUnderItsRoot() {
        var new = window
        new.append(contentsOf: [
            node("AXPopover", "Save options", depth: 1),
            node("AXGroup", depth: 2),
            node("AXButton", "Cancel", depth: 3),
            node("AXButton", "Save", depth: 3),
        ])
        let delta = TreeDelta.compute(from: window, to: new)
        #expect(delta.appeared.count == 1)
        let group = delta.appeared[0]
        #expect(group.root.role == "AXPopover")
        #expect(group.children.map(\.role) == ["AXGroup", "AXButton", "AXButton"])
        #expect(TreeDelta.render(delta)
            == "appeared: AXPopover 'Save options' containing [AXGroup, AXButton 'Cancel', AXButton 'Save']")
    }

    /// Vanishing is grouped the same way, computed on the old walk.
    @Test func vanishedSubtreeGroupsUnderItsRoot() {
        var old = window
        old.append(contentsOf: [
            node("AXSheet", "Confirm", depth: 1),
            node("AXButton", "Delete", depth: 2),
        ])
        let delta = TreeDelta.compute(from: old, to: window)
        #expect(delta.vanished.count == 1)
        #expect(delta.vanished[0].root.label == "Confirm")
        #expect(delta.vanished[0].children.map(\.label) == ["Delete"])
    }

    /// Reordering is not a change: pre-order positions shift whenever anything above them
    /// moves, and an agent's tokens should not be spent on that.
    @Test func reorderedElementsAreNotChanges() {
        var new = window
        new.swapAt(1, 3)
        let delta = TreeDelta.compute(from: window, to: new)
        #expect(delta.isEmpty)
    }

    /// The degrade signal: replacing the whole window contents drives the ratio toward 1,
    /// which is what the engine turns into "returning a full read".
    @Test func wholesaleReplacementReportsHighRatio() {
        let old = (0 ..< 30).map { node("AXStaticText", value: "old row \($0)") }
        let new = (0 ..< 30).map { node("AXStaticText", value: "fresh row \($0)") }
        let delta = TreeDelta.compute(from: old, to: new)
        #expect(delta.changeRatio > 0.9)
    }

    /// Duplicate elements diff by multiplicity: two identical buttons becoming three is
    /// one appearance.
    @Test func duplicateMultiplicityChangeIsOneAppearance() {
        let old = [node("AXButton", "OK"), node("AXButton", "OK")]
        let new = [node("AXButton", "OK"), node("AXButton", "OK"), node("AXButton", "OK")]
        let delta = TreeDelta.compute(from: old, to: new)
        #expect(delta.appeared.count == 1)
        #expect(delta.vanished.isEmpty)
        #expect(delta.valueChanges.isEmpty)
    }
}

/// The token store: bounded per process and overall, honest about eviction.
struct TreeSnapshotStoreTests {
    private func snapshot(pid: pid_t, scope: String = "window 'X'") -> TreeSnapshot {
        TreeSnapshot(pid: pid, scopeKey: "@window|*", scope: scope, truncated: false, nodes: [])
    }

    @Test func storedSnapshotIsRetrievableByItsToken() {
        let store = TreeSnapshotStore()
        let token = store.store(snapshot(pid: 42))
        #expect(store.snapshot(for: token)?.pid == 42)
        #expect(store.snapshot(for: "ax42-nonsense") == nil)
    }

    @Test func perProcessCapEvictsTheOldest() {
        let store = TreeSnapshotStore()
        let first = store.store(snapshot(pid: 42))
        for _ in 0 ..< 3 { _ = store.store(snapshot(pid: 42)) }
        #expect(store.snapshot(for: first) == nil)
    }

    @Test func deadProcessSnapshotsAreEvicted() {
        let store = TreeSnapshotStore()
        let dead = store.store(snapshot(pid: 41))
        let live = store.store(snapshot(pid: 42))
        store.evictDeadProcesses(livePIDs: [42])
        #expect(store.snapshot(for: dead) == nil)
        #expect(store.snapshot(for: live) != nil)
    }
}
