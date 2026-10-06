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
    private let windowServer: pid_t = 500
    private let security: pid_t = 600
    private let fullScreen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let virtualDisplay = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
    private let menuBar = CGRect(x: 0, y: 0, width: 2560, height: 30)

    private func occluder(_ point: CGPoint, target: pid_t?, _ windows: [Slot]) -> pid_t? {
        HardwareInput.occluder(
            at: point, target: target, ownPID: us, windows: windows, displays: [fullScreen, virtualDisplay],
        )
    }

    private var dockBackdrop: Slot { Slot(pid: dock, owner: "Dock", layer: 20, frame: fullScreen) }
    private var menuBarStrip: Slot { Slot(pid: windowServer, owner: "Window Server", layer: 24, frame: menuBar) }

    // MARK: - Occlusion: z-order relative to the target, failing closed

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

    /// The Dock's whole-display backing window sits above every layer-0 window; counting it
    /// would refuse every hardware click.
    @Test func dockBackdropDoesNotOcclude() {
        let windows = [menuBarStrip, dockBackdrop, Slot(pid: terminal, layer: 0, frame: fullScreen)]
        #expect(occluder(CGPoint(x: 400, y: 400), target: terminal, windows) == nil)
    }

    /// The exemption is owner *and* whole-display frame: a Dock window that is not a display's
    /// size, or a whole-display window from anyone else, still occludes.
    @Test func backdropExemptionNeedsOwnerAndDisplayFrame() {
        let target = Slot(pid: terminal, layer: 0, frame: fullScreen)
        let dockTile = Slot(pid: dock, owner: "Dock", layer: 20, frame: CGRect(x: 300, y: 1300, width: 800, height: 140))
        #expect(occluder(CGPoint(x: 400, y: 1350), target: terminal, [dockTile, target]) == dock)
        let shield = Slot(pid: security, owner: "SecurityAgent", layer: 2000, frame: fullScreen)
        #expect(occluder(CGPoint(x: 400, y: 400), target: terminal, [shield, target]) == security)
    }

    /// The menu bar strip is the window server's but not a whole display: a point in it
    /// would click the menu bar.
    @Test func menuBarStripAtThePointOccludes() {
        let windows = [menuBarStrip, dockBackdrop, Slot(pid: terminal, layer: 0, frame: fullScreen)]
        #expect(occluder(CGPoint(x: 400, y: 10), target: terminal, windows) == windowServer)
    }

    /// High-layer windows above the target take the click: a pop-up menu, a notification
    /// banner, an authorization dialog.
    @Test func highLayerWindowsAboveTheTargetOcclude() {
        let target = Slot(pid: terminal, layer: 0, frame: fullScreen)
        let popup = Slot(pid: game, layer: 101, frame: CGRect(x: 300, y: 300, width: 200, height: 200))
        #expect(occluder(CGPoint(x: 400, y: 400), target: terminal, [popup, dockBackdrop, target]) == game)
        let panel = Slot(pid: game, layer: 3, frame: CGRect(x: 300, y: 300, width: 200, height: 200))
        #expect(occluder(CGPoint(x: 400, y: 400), target: terminal, [panel, target]) == game)
    }

    @Test func ourOverlayAndTransparentWindowsNeverOcclude() {
        let windows = [
            Slot(pid: us, layer: 1000, frame: fullScreen),
            Slot(pid: game, layer: 101, frame: fullScreen, alpha: 0),
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

    /// No target window at the point: anything there, at any layer, takes the click; only an
    /// empty point (after the exemptions) passes.
    @Test func withoutATargetWindowAnythingThereOccludes() {
        let windows = [dockBackdrop, Slot(pid: terminal, layer: 0, frame: fullScreen)]
        #expect(occluder(CGPoint(x: 400, y: 400), target: game, windows) == terminal)
        #expect(occluder(CGPoint(x: 400, y: 10), target: game, [menuBarStrip]) == windowServer)
        #expect(occluder(CGPoint(x: 400, y: 400), target: game, [dockBackdrop]) == nil)
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

    /// A named point outside the element the hit test answered with is no aim: the click
    /// would land on something nobody resolved.
    @Test func namedPointOutsideTheElementIsNoAim() {
        let button = CGRect(x: 100, y: 100, width: 80, height: 30)
        #expect(GhostReach.aim(at: CGPoint(x: 400, y: 400), frame: button) == nil)
        #expect(GhostReach.aim(at: CGPoint(x: 120, y: 110), frame: button) == CGPoint(x: 120, y: 110))
        #expect(GhostReach.aim(at: CGPoint(x: 400, y: 400), frame: nil) == CGPoint(x: 400, y: 400))
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

    /// A real Return, Tab, Escape or Delete would submit, move focus, cancel or erase past the
    /// `--submit` rail, so control characters get no stroke even from a map that has one.
    @Test func controlCharactersGetNoKey() {
        let layout = KeyboardLayout(keys: [
            "\r": .init(keyCode: 36, shift: false), "\t": .init(keyCode: 48, shift: false),
            "\u{1b}": .init(keyCode: 53, shift: false), "\u{8}": .init(keyCode: 51, shift: false),
            "\u{7f}": .init(keyCode: 117, shift: false), "r": .init(keyCode: 15, shift: false),
        ])
        for control: Character in ["\n", "\r", "\t", "\u{1b}", "\u{8}", "\u{7f}", "\u{2028}", "\u{200b}"] {
            #expect(layout.key(for: control) == nil)
        }
        #expect(layout.key(for: "r")?.keyCode == 15)
        #expect(layout.key(for: "👍") == nil)
    }

    /// The live layout: letters and space map to real keys, and no control character is in
    /// the table at all.
    @MainActor
    @Test func currentLayoutMapsPrintableCharactersOnly() {
        let layout = KeyboardLayout.current(asciiCapable: false)
        #expect(layout.keys.keys.allSatisfy(KeyboardLayout.isPrintable))
        for control: Character in ["\r", "\n", "\t", "\u{1b}", "\u{8}", "\u{7f}", "\u{3}"] {
            #expect(layout.keys[control] == nil)
        }
        #expect(layout.key(for: " ") != nil)
        #expect(layout.key(for: "r") != nil)
        #expect(layout.key(for: "R")?.shift == true)
    }
}
