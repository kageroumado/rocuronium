import Testing
@testable import Rocuronium

struct DisabledMenuEvidenceTests {
    private var acceptedPress: Evidence {
        Evidence(action: "press", target: "Close", tentacle: .accessibility, verdict: .unverifiable,
                 readback: nil, pixelDelta: 0, focusBefore: nil, focusAfter: nil,
                 cursorMoved: false, frontmostChanged: false, frontmostBecameTarget: false,
                 attempts: [.init(tentacle: .accessibility, outcome: "press accepted")], referral: nil)
    }

    private var appearedGroup: TreeDelta.Delta {
        TreeDelta.compute(from: [], to: [.init(role: "AXGroup", label: "", value: "", depth: 0)])
    }

    @Test func disabledCloseKeepsIncidentalChangesAsObservations() {
        let result = acceptedPress.addingTreeEvidence(appearedGroup, canConfirm: false)
        #expect(result.verdict == .unverifiable)
        #expect(result.succeeded == false)
        #expect(result.readback == nil)
        #expect(result.treeChanges == 1)
        #expect(result.treeDelta == "appeared: AXGroup")
    }

    @Test func actualWindowClosureConfirmsEvenWhenItemReportedDisabled() {
        let result = acceptedPress.confirmedByWindowCountChange(before: 1, after: 0)
            .addingTreeEvidence(appearedGroup, canConfirm: false)
        #expect(result.verdict == .confirmed)
        #expect(result.readback == "the target's on-screen window count changed 1 → 0")
    }

    /// A change that carries content: a bare container appearing confirms nothing on its own
    /// (WebKit adds one when a press only moves focus), so the enabled case uses a row.
    private var appearedRow: TreeDelta.Delta {
        TreeDelta.compute(from: [], to: [.init(role: "AXStaticText", label: "", value: "Untitled 2", depth: 0)])
    }

    @Test func enabledMenuKeepsStructuralConfirmation() {
        #expect(acceptedPress.addingTreeEvidence(appearedRow).verdict == .confirmed)
        #expect(acceptedPress.addingTreeEvidence(appearedGroup).verdict == .unverifiable)
    }
}
