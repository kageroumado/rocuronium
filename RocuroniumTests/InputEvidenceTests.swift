import Testing
@testable import Rocuronium

struct InputEvidenceTests {
    private func hardware(keyboardOnly: Bool, cursorMoved: Bool = false) -> Evidence {
        Evidence(action: "input", target: "scratch", tentacle: .hardwareInput, verdict: .unverifiable,
                 readback: nil, pixelDelta: nil, focusBefore: nil, focusAfter: nil,
                 cursorMoved: cursorMoved, frontmostChanged: false, frontmostBecameTarget: false,
                 attempts: [], referral: nil, keyboardOnly: keyboardOnly)
    }

    @Test func keyboardLeavesTheCursorWithTheHuman() {
        var key = hardware(keyboardOnly: true)
        key.matchedBy = "exact"
        key.suggestion = "inspect the scratch window"
        let withCaptureFailure = key.addingVisualEvidence(delta: nil, fault: "capture unavailable")
        #expect(withCaptureFailure.cursorMovedByUs == false)
        #expect(withCaptureFailure.matchedBy == "exact")
        #expect(withCaptureFailure.suggestion == key.suggestion)
        #expect(key.cursorMovedByUs == false)
        #expect(key.cursorMovedByUser == false)
        #expect(key.confirmedByWindowCountChange(before: 2, after: 1).cursorMovedByUs == false)
        #expect(hardware(keyboardOnly: true, cursorMoved: true).cursorMovedByUser)
    }

    @Test func restoredPointerDeliveryStillReportsTakingTheCursor() {
        #expect(hardware(keyboardOnly: false).cursorMovedByUs)
        #expect(hardware(keyboardOnly: false).cursorMovedByUser == false)
    }
}
