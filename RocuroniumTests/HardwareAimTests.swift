import CoreGraphics
import Testing
@testable import Rocuronium

/// The hardware tentacle's two pure decisions: where a click lands, and who would receive it.
struct HardwareAimTests {
    private typealias Slot = HardwareInput.WindowSlot

    private let game: pid_t = 100
    private let terminal: pid_t = 200
    private let dock: pid_t = 300
    private let us: pid_t = 400
    private let fullScreen = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    private func occluder(_ point: CGPoint, target: pid_t?, _ windows: [Slot]) -> pid_t? {
        HardwareInput.occluder(at: point, target: target, ownPID: us, windows: windows)
    }

    // MARK: - Occlusion: z-order relative to the target

    /// The measured refusal: a fullscreen game on a raised level, frontmost, with an ordinary
    /// window behind it. The window behind must not be blamed.
    @Test func windowBehindARaisedTargetDoesNotOcclude() {
        let windows = [
            Slot(pid: game, layer: 25, frame: fullScreen),
            Slot(pid: terminal, layer: 0, frame: CGRect(x: 580, y: 184, width: 1280, height: 1161)),
        ]
        #expect(occluder(CGPoint(x: 1280, y: 720), target: game, windows) == nil)
        #expect(occluder(CGPoint(x: 203, y: 647), target: game, windows) == nil)
    }

    @Test func windowAboveTheTargetOccludes() {
        let windows = [
            Slot(pid: terminal, layer: 0, frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            Slot(pid: game, layer: 0, frame: fullScreen),
        ]
        #expect(occluder(CGPoint(x: 100, y: 100), target: game, windows) == terminal)
    }

    /// The aim point decides, not the window: the same stack is clear where the window above
    /// does not reach.
    @Test func onlyTheAimPointIsTested() {
        let windows = [
            Slot(pid: terminal, layer: 0, frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            Slot(pid: game, layer: 0, frame: fullScreen),
        ]
        #expect(occluder(CGPoint(x: 1500, y: 900), target: game, windows) == nil)
    }

    /// The Dock and menu bar keep full-screen backing windows above every layer-0 window;
    /// counting them would refuse every hardware click.
    @Test func systemBackingWindowsAboveTheTargetDoNotOcclude() {
        let windows = [
            Slot(pid: dock, layer: 24, frame: CGRect(x: 0, y: 0, width: 2560, height: 30)),
            Slot(pid: dock, layer: 20, frame: fullScreen),
            Slot(pid: terminal, layer: 0, frame: fullScreen),
        ]
        #expect(occluder(CGPoint(x: 400, y: 400), target: terminal, windows) == nil)
    }

    /// A floating panel (layer 3) is in the application band and does cover what is below it.
    @Test func floatingPanelAboveTheTargetOccludes() {
        let windows = [
            Slot(pid: game, layer: 3, frame: CGRect(x: 300, y: 300, width: 200, height: 200)),
            Slot(pid: terminal, layer: 0, frame: fullScreen),
        ]
        #expect(occluder(CGPoint(x: 400, y: 400), target: terminal, windows) == game)
    }

    @Test func ourOverlayAndTransparentWindowsNeverOcclude() {
        let windows = [
            Slot(pid: us, layer: 0, frame: fullScreen),
            Slot(pid: dock, layer: 0, frame: fullScreen, alpha: 0),
            Slot(pid: terminal, layer: 0, frame: fullScreen),
        ]
        #expect(occluder(CGPoint(x: 400, y: 400), target: terminal, windows) == nil)
    }

    /// Our own app as the target (the demo stage) is still found.
    @Test func ourOwnWindowCanBeTheTarget() {
        let windows = [
            Slot(pid: us, layer: 0, frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            Slot(pid: terminal, layer: 0, frame: fullScreen),
        ]
        #expect(occluder(CGPoint(x: 100, y: 100), target: us, windows) == nil)
    }

    /// The target's own windows stacked above one another are never occluders.
    @Test func targetsOwnWindowsDoNotOcclude() {
        let windows = [
            Slot(pid: game, layer: 0, frame: CGRect(x: 100, y: 100, width: 300, height: 300)),
            Slot(pid: game, layer: 0, frame: fullScreen),
        ]
        #expect(occluder(CGPoint(x: 200, y: 200), target: game, windows) == nil)
    }

    @Test func withoutATargetWindowTheTopmostApplicationWindowDecides() {
        let windows = [
            Slot(pid: dock, layer: 20, frame: fullScreen),
            Slot(pid: terminal, layer: 0, frame: fullScreen),
        ]
        #expect(occluder(CGPoint(x: 400, y: 400), target: game, windows) == terminal)
        #expect(occluder(CGPoint(x: 400, y: 400), target: terminal, []) == nil)
        #expect(occluder(CGPoint(x: 400, y: 400), target: nil, windows) == terminal)
    }

    // MARK: - Aim

    /// A coordinate click lands on the coordinate, not on the center of whatever element the hit
    /// test found under it — a whole web view or game window centers hundreds of points away.
    @Test func aimPrefersTheNamedPoint() {
        let webView = CGRect(x: 995, y: 100, width: 1330, height: 1200)
        let aim = GhostReach.aim(at: CGPoint(x: 1083, y: 737), frame: webView)
        #expect(aim == CGPoint(x: 1083, y: 737))
    }

    @Test func aimFallsBackToTheFrameCenter() {
        let aim = GhostReach.aim(at: nil, frame: CGRect(x: 100, y: 200, width: 40, height: 20))
        #expect(aim == CGPoint(x: 120, y: 210))
    }

    /// A closed menu item's 0×0 rect at the screen corner is no aim at all.
    @Test func zeroAreaFrameIsNoAim() {
        #expect(GhostReach.aim(at: nil, frame: CGRect(x: 0, y: 1440, width: 0, height: 0)) == nil)
        #expect(GhostReach.aim(at: nil, frame: nil) == nil)
    }

    // MARK: - Keys

    @Test func lineFeedTypesWithReturn() {
        let map = ["\r": KeyLayout.Stroke(keyCode: 36, shift: false), "r": .init(keyCode: 15, shift: false)]
        #expect(KeyLayout.stroke(for: "\n", in: map)?.keyCode == 36)
        #expect(KeyLayout.stroke(for: "r", in: map)?.keyCode == 15)
        #expect(KeyLayout.stroke(for: "👍", in: map) == nil)
    }

    /// The live layout: whatever is selected, letters and Return map to real keys.
    @MainActor
    @Test func currentLayoutMapsLettersAndReturn() {
        let map = KeyLayout.currentMap()
        #expect(!map.isEmpty)
        #expect(KeyLayout.stroke(for: "\n", in: map)?.keyCode == 36)
        #expect(map["r"] != nil)
        #expect(map["R"]?.shift == true)
    }
}
