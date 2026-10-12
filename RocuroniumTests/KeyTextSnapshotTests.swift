import Foundation
import Testing
@testable import Rocuronium

struct KeyTextSnapshotTests {
    @Test func singleCharacterInsertionConfirms() {
        let before = KeyTextSnapshot(value: "viewer test", selection: NSRange(location: 11, length: 0))
        let after = KeyTextSnapshot(value: "viewer testr", selection: NSRange(location: 12, length: 0))
        #expect(after.change(from: before) == "text changed: viewer testr")
    }

    @Test func caretMovementConfirmsWithoutTextChange() {
        let before = KeyTextSnapshot(value: "test", selection: NSRange(location: 4, length: 0))
        let after = KeyTextSnapshot(value: "test", selection: NSRange(location: 3, length: 0))
        #expect(after.change(from: before) == "selection changed: location 3, length 0")
    }

    @Test func unreadableAndUnchangedValuesStayInconclusive() {
        let before = KeyTextSnapshot(value: "test", selection: nil)
        #expect(before.change(from: before) == nil)
        let unreadable = KeyTextSnapshot(value: nil, selection: nil)
        #expect(unreadable.change(from: before) == nil)
        #expect(before.change(from: unreadable) == nil)
    }

    @Test func deletionToEmptyConfirms() {
        #expect(KeyTextSnapshot(value: "", selection: nil).change(from: .init(value: "r", selection: nil)) == "text changed: ")
    }
}
