import CoreGraphics
import Testing
@testable import Rocuronium

/// The label resolver: the two tiers, `--exact`, and the one-exact-among-several preference.
struct LabelMatchingTests {
    private func classify(_ names: [String], value: String? = nil, _ needle: String, exact: Bool = false) -> LabelMatching.Classification? {
        LabelMatching.classify(names: names, value: value, needle: needle, exactOnly: exact)
    }

    @Test func wholeStringIsExactIgnoringCaseAndWhitespace() {
        #expect(classify(["  Save "], "save") == .init(tier: .name, exact: true))
        #expect(classify(["Save As…"], "save") == .init(tier: .name, exact: false))
        #expect(classify(["Save As…"], "save", exact: true) == nil)
    }

    @Test func valueIsTheSecondTier() {
        #expect(classify(["text"], value: "符合", "符合") == .init(tier: .value, exact: true))
        #expect(classify(["text"], value: "不符合", "符合") == .init(tier: .value, exact: false))
        #expect(classify(["text"], value: "不符合", "符合", exact: true) == nil)
        #expect(classify([""], value: nil, "x") == nil)
    }

    @Test func anEmptyNeedleMatchesNothing() {
        #expect(classify(["Save"], value: "Save", "  ") == nil)
    }

    /// The bilibili case: three value matches, one of them whole — it resolves, as `exact`.
    @Test func oneExactAmongSubstringsIsPreferred() {
        let classifications = [
            classify(["text"], value: "不符合", "符合"),
            classify(["text"], value: "你的性格是否符合以下描述？", "符合"),
            classify(["text"], value: "符合", "符合"),
        ]
        #expect(LabelMatching.pick(classifications) == .one(index: 2, matchedBy: .exact))
    }

    @Test func twoExactMatchesStayAmbiguous() {
        let classifications = [
            classify(["Delete"], "delete"),
            classify(["Delete"], "delete"),
            classify(["Delete All"], "delete"),
        ]
        #expect(LabelMatching.pick(classifications) == .ambiguous(indices: [0, 1, 2]))
    }

    @Test func aNameMatchOutranksEveryValueMatch() {
        let classifications = [
            classify(["text"], value: "save", "save"),
            classify(["Save As…"], "save"),
        ]
        #expect(LabelMatching.tier(classifications) == [1])
        #expect(LabelMatching.pick(classifications) == .one(index: 1, matchedBy: .only))
    }

    @Test func noMatchIsNone() {
        #expect(LabelMatching.pick([nil, nil]) == .none)
    }
}

/// Labels derived from a control's row: same-line text to the left wins.
struct ControlContextTests {
    @Test func sameLineLeftTextNamesTheSwitch() {
        let control = CGRect(x: 300, y: 100, width: 40, height: 20)
        let texts: [(text: String, frame: CGRect)] = [
            ("Section", CGRect(x: 20, y: 60, width: 80, height: 16)),
            ("ghost: off", CGRect(x: 360, y: 102, width: 70, height: 16)),
            ("Ghost Mode", CGRect(x: 20, y: 102, width: 90, height: 16)),
        ]
        #expect(AXElement.nearestText(to: control, among: texts) == 2)
    }

    @Test func noTextNoLabel() {
        #expect(AXElement.nearestText(to: .zero, among: []) == nil)
    }
}

/// Which scroll area a label-less scroll aims at.
struct ScrollAreasTests {
    @Test func theLargestScrollableAreaWins() {
        let candidates = [
            ScrollAreas.Candidate(frame: CGRect(x: 0, y: 0, width: 200, height: 600), scrollable: true),
            ScrollAreas.Candidate(frame: CGRect(x: 200, y: 0, width: 800, height: 600), scrollable: true),
            ScrollAreas.Candidate(frame: CGRect(x: 0, y: 0, width: 2000, height: 2000), scrollable: false),
        ]
        #expect(ScrollAreas.choose(candidates, requested: nil) == .index(1))
    }

    @Test func withNoneScrollableTheLargestWins() {
        let candidates = [
            ScrollAreas.Candidate(frame: CGRect(x: 0, y: 0, width: 10, height: 10), scrollable: false),
            ScrollAreas.Candidate(frame: CGRect(x: 0, y: 0, width: 20, height: 20), scrollable: false),
        ]
        #expect(ScrollAreas.choose(candidates, requested: nil) == .index(1))
    }

    @Test func aRequestedIndexIsHonoredOrRefused() {
        let candidates = [ScrollAreas.Candidate(frame: nil, scrollable: true)]
        #expect(ScrollAreas.choose(candidates, requested: 0) == .index(0))
        #expect(ScrollAreas.choose(candidates, requested: 3) == .outOfRange(count: 1))
        #expect(ScrollAreas.choose([], requested: nil) == .none)
    }
}

/// Which of several same-named running apps `--app` means.
struct AppInstancePickerTests {
    private let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let elsewhere = CGRect(x: 900, y: 0, width: 400, height: 300)

    @Test func theFrontmostInstanceWins() {
        let pick = AppInstancePicker.pick([
            .init(pid: 1, frontmost: false, windowFrames: [window]),
            .init(pid: 2, frontmost: true, windowFrames: []),
        ], aim: nil)
        #expect(pick == .chosen(pid: 2, reason: "frontmost"))
    }

    @Test func theOnlyWindowAtTheAimPointWins() {
        let pick = AppInstancePicker.pick([
            .init(pid: 1, frontmost: false, windowFrames: [window]),
            .init(pid: 2, frontmost: false, windowFrames: [elsewhere]),
        ], aim: CGPoint(x: 1000, y: 100))
        guard case let .chosen(pid, _) = pick else {
            Issue.record("expected a pick, got \(pick)")
            return
        }
        #expect(pid == 2)
    }

    @Test func theOnlyInstanceWithWindowsWins() {
        let pick = AppInstancePicker.pick([
            .init(pid: 1, frontmost: false, windowFrames: []),
            .init(pid: 2, frontmost: false, windowFrames: [window]),
        ], aim: nil)
        #expect(pick == .chosen(pid: 2, reason: "the only one with an on-screen window"))
    }

    @Test func twoVisibleBackgroundInstancesAreRefused() {
        let pick = AppInstancePicker.pick([
            .init(pid: 1, frontmost: false, windowFrames: [window]),
            .init(pid: 2, frontmost: false, windowFrames: [elsewhere]),
        ], aim: nil)
        #expect(pick == .ambiguous)
    }
}
