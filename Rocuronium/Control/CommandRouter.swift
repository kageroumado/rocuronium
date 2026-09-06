import AppKit
import ApplicationServices
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Decodes a JSON request, runs it against the engine, and encodes the reply.
///
/// Every reply carries the current presence reading, not just the result. The agent on the
/// other end is the one with task context, so it needs to know whether a human is at the
/// keyboard in order to decide how forceful to be — that has to arrive with every answer,
/// not only when asked for.
@MainActor
@Observable
final class CommandRouter {
    /// True while an action is in flight. The menu bar icon reads this, so a user can always
    /// tell at a glance whether an agent currently has hands.
    private(set) var isDriving = false

    /// Windows on the virtual display that nobody parked, as of the last maintenance count.
    /// The menu bar badges on this — an invisible window deserves a visible indicator.
    var virtualDisplayStrayCount: Int { virtualDisplay.strayCount }

    /// All accessibility work happens here, off the main actor. See `Engine`.
    private let engine = Engine()
    /// The most recent capture per screenshot target — what `screenshot --since` diffs against.
    private let frames = FrameStore()
    private let virtualDisplay: VirtualDisplayBridge
    /// Keeps the display awake for the whole agent session, not just per action.
    private let adrafinil = AdrafinilBridge()
    /// The visible-agent chrome: tint, bezel, jellyfish, ⌃⌥⇧⎋. Shown per the policy in
    /// `execute` — cursor-taking commands always, everything else behind the toggle.
    let overlay = PresenceOverlayController()
    /// What the agent did, one line per acting command; the popover, the bezel, and the
    /// `activity` verb all read from here.
    let activityLog = ActivityLog()
    /// The deterministic practice window every verb can be exercised against.
    let demoStage = DemoStageController()

    init() {
        virtualDisplay = VirtualDisplayBridge(engine: engine)
        PresenceOverlayController.shared = overlay
        PresenceOverlayController.installRelayHooks()
        overlay.onEmergencyStop = { [activityLog] in
            activityLog.append(
                action: "halt", target: "⌃⌥⇧⎋",
                verdict: "halted",
                summary: "Emergency stop — agent verbs refused until resumed from the menu bar",
            )
        }
        // A previous display teardown that never un-parked (a crash, a kill -9) leaves
        // windows stranded where no display reaches. Sweep them home once, shortly after
        // startup — the AX trees need a moment to answer after launch.
        Task(name: "startup stranded-window sweep") { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await self?.sweepStrandedWindows()
        }
    }

    /// Moves every window whose frame is on no current display back onto the main screen.
    /// `windows` already flags exactly these; this is the recovery half.
    private func sweepStrandedWindows() async {
        guard DisplayWake.perceptionIsReliable else { return }
        let displays = virtualDisplay.displayBounds
        guard !displays.isEmpty else { return }
        let main = CGDisplayBounds(CGMainDisplayID())
        let home = CGPoint(x: main.origin.x + 40, y: main.origin.y + 40)
        let ownPid = ProcessInfo.processInfo.processIdentifier
        for application in NSWorkspace.shared.runningApplications where application.activationPolicy == .regular {
            let pid = application.processIdentifier
            guard pid != ownPid, let windows = try? await engine.windowList(pid: pid) else { continue }
            for window in windows where !window.minimized {
                guard let frame = window.frame else { continue }
                let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                guard !displays.contains(where: { $0.contains(center) }) else { continue }
                guard (try? await engine.moveWindow(pid: pid, title: window.title, to: home)) != nil else { continue }
                activityLog.append(
                    action: "sweep",
                    target: "'\(window.title)' (\(application.localizedName ?? "pid \(pid)"))",
                    verdict: "ok",
                    summary: "startup sweep — the window was on no display; moved to (\(Int(home.x)), \(Int(home.y)))",
                )
            }
        }
    }

    /// The running plan executor, if any. Kept so `resumeFromHalt` can wake a paused plan.
    private var planExecutor: PlanExecutor?

    /// Clears the ⌃⌥⇧⎋ halt. Reachable only from the menu bar popover — human-only by
    /// design; no socket verb calls this, so an agent can never un-halt itself.
    func resumeFromHalt() {
        EmergencyStop.resume()
        planExecutor?.resume()
        activityLog.append(
            action: "resume", target: "menu bar",
            verdict: "resumed",
            summary: "Agent commands resumed by the human",
        )
    }

    struct Request: Decodable {
        let command: String
        var app: String?
        /// Targets a process directly, bypassing name resolution — the only unambiguous
        /// address when two instances share a bundle id (`open -n`).
        var pid: pid_t?
        var label: String?
        /// Narrows a label match by element role ("button" or "AXButton") — the answer when
        /// two roles share the same text and "be more specific" has no more-specific label.
        var role: String?
        var text: String?
        var x: Double?
        var y: Double?
        /// Opt-in to the cursor-stealing tentacle. Absent means no.
        var allowHardwareInput: Bool?
        /// Opt-in to sending control characters (Return, Tab). Absent means no: a newline in a
        /// composer submits, and "type" must not be able to send a message by accident.
        var submit: Bool?
        /// Subcommand for verbs that have one (`display acquire|release|status`).
        var action: String?
        /// Why a virtual display lease is being taken; recorded on the lease.
        var reason: String?
        /// Lease duration. The bridge's 30-minute backstop applies when absent.
        var minutes: Double?
        /// Lease id to release.
        var lease: String?
        /// Where a screenshot should be written. A default under Application Support otherwise.
        var path: String?
        /// Region size for screenshots, paired with x/y.
        var w: Double?
        var h: Double?
        /// A keyboard shortcut for `shortcut`, e.g. "cmd+a".
        var keys: String?
        /// Report which menu item a shortcut resolves to without pressing it.
        var resolveOnly: Bool?
        /// Press a shortcut that resolves to a session- or data-destroying menu item.
        var confirm: Bool?
        /// For `wait`: wait for the element to disappear rather than appear.
        var gone: Bool?
        /// For `wait`: seconds to block, at most 25 — the socket cancels requests at 30.
        var timeout: Double?
        /// For `scroll`: pixel deltas. Positive dy reveals content further down.
        var dx: Double?
        var dy: Double?
        /// For `scroll`: absolute position, 0 (top) to 1 (bottom), via the scroll bar.
        var to: Double?
        /// For `scroll`: step until this string is legible in the frame (local OCR per step).
        var untilText: String?
        /// For `statusitem`: press the item rather than just listing.
        var press: Bool?
        /// For `move`/`drag`: path points as "x,y" strings — start, destination, and
        /// intermediate waypoints ("x,y x,y …") the curve passes through.
        var start: String?
        var end: String?
        var via: String?
        /// For `move`/`drag`: gesture length in seconds. Distance-based default otherwise.
        var duration: Double?
        /// For `move`/`drag`: linear, ease-in, ease-out, or ease-in-out (the default).
        var easing: String?
        /// For `drag`: which button is held — left (the default) or right. For `click`:
        /// which button is clicked.
        var button: String?
        /// For `click`: number of clicks (1, or 2 for a double-click).
        var count: Double?
        /// For `click`: modifier keys held during the click, comma-separated
        /// (cmd,shift,option,control,fn).
        var modifiers: String?
        /// For `move`/`drag`: put the cursor back where it was after the gesture. Off by
        /// default — a hover only means something while the cursor stays on the target.
        var restore: Bool?
        /// For `read`/`screenshot`: an observation token from a prior reply of the same
        /// verb; the reply becomes the delta against that observation.
        var since: String?
        /// For `click`/`shortcut`/`menu`: walk the window's accessibility tree even when it
        /// is large enough that the tree-delta evidence channel would otherwise skip it, so
        /// the reply carries what changed. Off by default — one walk on a huge tree is slow.
        var observe: Bool?
        /// For `read`/`find`: OCR the window's pixels into text rows instead of (or, on an
        /// empty tree, in addition to) walking accessibility — the way to read an app whose
        /// AX tree is empty or lying. Needs Screen Recording.
        var ocr: Bool?
        /// For `find`: list every element carrying a frame, not just editables — "show me
        /// everything you can see". `--role` still narrows it.
        var all: Bool?
        /// For `find`: page the matches. `limit` defaults to 20; `offset` skips that many.
        var limit: Double?
        var offset: Double?
        /// For `wait`: a `PlanGuard` to poll until it passes — the same postcondition grammar
        /// `plan` steps use. Supersedes the `--label`/`--gone` sugar when present.
        var expect: PlanGuard?
        /// A window title substring, to scope a verb to one of an app's windows rather than
        /// its primary window: `find`, `read`, `click`, `type`, `wait`, `screenshot`, `move`,
        /// `drag`, `park`. Ambiguity is refused with the titles listed.
        var window: String?
        /// For `move`/`drag`: milliseconds to hold at the destination before reading what the
        /// gesture revealed — long enough for a tooltip (AppKit shows them after ~1 s).
        var dwell: Double?

        /// For `plan`: the step list.
        var steps: [SequencePlan.Step]?
        /// For `plan`: ghost (default) or visible.
        var profile: String?
    }

    /// Bounds every number that arrives over the socket, before it reaches arithmetic that
    /// traps. Measured: `Duration.seconds(1e30 * 60)` dies with "Overflow in multiplication",
    /// and `Int(Double.infinity.rounded())` dies with "outside the representable range" —
    /// either one takes down the app holding the Accessibility grant, the control socket, and
    /// every lease, and a crashed app never runs its virtual-display teardown. The CLI's
    /// `Double(argument)` happily parses "inf", so this is one malformed request away.
    private enum Bounds {
        /// Well past any real display arrangement, far short of anything that overflows.
        static let coordinate = 1_000_000.0
        static let extent = 100_000.0
        static let leaseMinutes = 24.0 * 60
    }

    private static func finite(_ value: Double?, limit: Double) -> Double? {
        guard let value, value.isFinite, abs(value) <= limit else { return nil }
        return value
    }

    /// Rejects the whole request rather than silently clamping: a caller who asked to click
    /// at infinity has a bug, and quietly clicking at the edge of the screen instead would
    /// act on a coordinate nobody chose.
    private func validate(_ request: Request) -> String? {
        for (name, value) in [("x", request.x), ("y", request.y)] where value != nil {
            guard Self.finite(value, limit: Bounds.coordinate) != nil else {
                return "'\(name)' must be a finite coordinate within ±\(Int(Bounds.coordinate))"
            }
        }
        for (name, value) in [("w", request.w), ("h", request.h)] where value != nil {
            guard Self.finite(value, limit: Bounds.extent) != nil else {
                return "'\(name)' must be a finite size no greater than \(Int(Bounds.extent))"
            }
        }
        if let minutes = request.minutes {
            guard let minutes = Self.finite(minutes, limit: Bounds.leaseMinutes), minutes > 0 else {
                return "'minutes' must be between 0 and \(Int(Bounds.leaseMinutes))"
            }
        }
        return nil
    }

    func route(_ data: Data) async -> Data {
        do {
            let request = try JSONDecoder().decode(Request.self, from: data)
            if let complaint = validate(request) {
                return encode(["ok": false, "error": complaint])
            }
            let reply = try await execute(request)
            if Self.actingVerbs.contains(request.command) {
                activityLog.append(
                    action: request.command,
                    target: Self.target(of: request),
                    verdict: reply["verdict"] as? String
                        ?? (reply["ok"] as? Bool == true ? "ok" : "refused"),
                    summary: reply["summary"] as? String ?? reply["error"] as? String ?? "",
                )
                overlay.commandFinished(reply)
            }
            return encode(reply)
        } catch {
            // Interpolating a Swift error enum prints its case name ("notInstalled"), which
            // tells the caller nothing; the description written for humans is the reply.
            let description = (error as? any LocalizedError)?.errorDescription ?? "\(error)"
            var reply: [String: Any] = ["ok": false, "error": description]
            // The occlusion refusal carries a machine-readable next move alongside the prose.
            if case let Engine.EngineError.occludedTarget(_, suggestion) = error {
                reply["suggestion"] = suggestion
            }
            return encode(reply)
        }
    }

    // MARK: - Commands

    /// The verbs that do something to the machine — the set the activity log records, the
    /// overlay narrates, and the ⌃⌥⇧⎋ halt refuses.
    private static let actingVerbs: Set<String> = [
        "type", "click", "scroll", "shortcut", "menu", "key",
        "move", "drag", "launch", "activate", "park", "statusitem",
    ]

    /// One phrase for the bezel and the log: what the command aimed at.
    private static func target(of request: Request) -> String {
        var parts: [String] = []
        if let label = request.label { parts.append("'\(label)'") }
        if let keys = request.keys { parts.append("'\(keys)'") }
        if let path = request.path, request.command == "menu" { parts.append("'\(path)'") }
        if let end = request.end { parts.append("to \(end)") }
        else if let x = request.x, let y = request.y { parts.append("(\(Int(x)), \(Int(y)))") }
        if let app = request.app { parts.append(parts.isEmpty ? app : "in \(app)") }
        return parts.isEmpty ? "focused element" : parts.joined(separator: " ")
    }

    private func execute(_ request: Request) async throws -> [String: Any] {
        // The ⌃⌥⇧⎋ halt refuses everything that perceives or acts. `status`, `diag`, and
        // `activity` still answer — an agent must be able to learn *why* its verbs stopped
        // working — and no socket verb can clear the flag: resume is the popover button.
        if EmergencyStop.isHalted, !["status", "diag", "activity"].contains(request.command) {
            return ["ok": false, "error": EmergencyStop.refusalMessage, "halted": true]
        }
        // Any command that perceives or acts marks the session active, which places (and
        // keeps renewing) the session-level display hold. Status-shaped commands do not:
        // a monitoring loop polling `status` must not pin the display awake all night.
        switch request.command {
        case "status", "diag", "request-capture", "display", "activity", "demo": break
        default:
            adrafinil.noteActivity()
            // A command aimed at an app with a parked window renews that window's
            // auto-lease: the lease being used is the lease still being wanted.
            if virtualDisplay.activeLease != nil, let pid = try? resolve(request) {
                virtualDisplay.renewAutoLease(touching: pid)
            }
        }
        // The overlay policy: cursor-taking work is always shown — hardware-input opt-ins
        // and the path verbs, which take the real cursor by construction — and everything
        // else only when the "show for all actions" toggle is on. Ghost tentacles are invisible
        // by design; the toggle is for watching, not for safety.
        if Self.actingVerbs.contains(request.command),
           request.allowHardwareInput == true
           || request.command == "move" || request.command == "drag"
           || overlay.model.showForAllActions {
            overlay.begin(action: "\(request.command) \(Self.target(of: request))…")
        }
        if request.command == "plan" {
            return try await plan(request)
        }
        return try await dispatch(request)
    }

    /// The raw command switch — no overlay, no activity tracking, no halt check.
    /// Called directly by both `execute()` (with its wrappers) and the plan executor.
    func dispatch(_ request: Request) async throws -> [String: Any] {
        return switch request.command {
        case "status": status()
        case "diag": await diagnose()
        case "request-capture": requestCapture()
        case "find": try await find(request)
        case "read": try await read(request)
        case "apps": apps()
        case "windows": try await windows(request)
        case "type": try await typeCommand(request)
        case "click": try await act(request, action: .click)
        case "scroll": try await scroll(request)
        case "shortcut": try await shortcut(request)
        case "menu": try await menu(request)
        case "key": try await key(request)
        case "move": try await trace(request, dragging: false)
        case "drag": try await trace(request, dragging: true)
        case "wait": try await wait(request)
        case "launch": try await launch(request)
        case "activate": try await activate(request)
        case "display": try await display(request)
        case "park": try await park(request)
        case "screenshot": try await screenshot(request)
        case "statusitem": try await statusItem(request)
        case "activity": activity()
        case "demo": demo(request)
        default: ["ok": false, "error": "unknown command '\(request.command)'"]
        }
    }

    /// Resolves an app name or pid from a request. Exposed for the plan executor's guard
    /// evaluation, which needs the pid to check windows and AX tree state.
    func resolvePid(_ request: Request) -> pid_t? {
        try? resolve(request)
    }

    /// Opens (reset), re-shows, or hides the demo stage. The reply carries the window's
    /// fixed frame in the same top-left coordinates every other verb speaks, so a test can
    /// aim at the stage without a `windows` round-trip.
    private func demo(_ request: Request) -> [String: Any] {
        switch request.action {
        case "hide":
            demoStage.hide()
            return ["ok": true, "visible": demoStage.isVisible, "summary": "demo stage hidden"]
        case "show", "reset", nil:
            demoStage.show(reset: request.action != "show")
            return [
                "ok": true,
                "visible": demoStage.isVisible,
                "reset": request.action != "show",
                "summary": "demo stage is up at (720, 200), 560×720 — fixed and reset unless action:show; "
                    + "drive it with --app Rocuronium",
            ]
        case "render":
            return renderJellyfish(request)
        default:
            return ["ok": false, "error": "unknown demo action '\(request.action ?? "")' — use show, reset, hide, or render"]
        }
    }

    private func renderJellyfish(_ request: Request) -> [String: Any] {
        let w = request.w ?? 660
        let h = request.h ?? 400
        guard let path = request.path else {
            return ["ok": false, "error": "'demo render' requires --path <file.png>"]
        }
        guard path.hasSuffix(".png") else {
            return ["ok": false, "error": "path must end in .png"]
        }

        let style: JellyStyle = .sparkler
        let time = 0.35

        let opaque = request.reason == "opaque"
        let view = Canvas { context, size in
            if opaque {
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: Color(red: 0.94, green: 0.92, blue: 0.97), location: 0),
                            .init(color: Color(red: 0.88, green: 0.84, blue: 0.95), location: 0.5),
                            .init(color: Color(red: 0.82, green: 0.76, blue: 0.92), location: 1),
                        ]),
                        startPoint: CGPoint(x: size.width / 2, y: 0),
                        endPoint: CGPoint(x: size.width / 2, y: size.height),
                    ),
                )
            }
            let jellyW = size.width * 0.58
            let jellyH = jellyW * 1.3
            let rect = CGRect(
                x: (size.width - jellyW) / 2,
                y: size.height * 0.03,
                width: jellyW,
                height: jellyH,
            )
            if opaque {
                context.addFilter(.shadow(color: .black.opacity(0.18), radius: 12, y: 8))
            }
            JellyfishArt.draw(in: context, rect: rect, time: time, phase: .idle, style: style)
        }
        .frame(width: w, height: h)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            return ["ok": false, "error": "ImageRenderer failed"]
        }
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return ["ok": false, "error": "cannot create PNG at '\(path)'"]
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return ["ok": false, "error": "failed to write PNG"]
        }
        return [
            "ok": true,
            "path": path,
            "width": image.width,
            "height": image.height,
            "summary": "rendered \(style.rawValue) jellyfish at \(image.width)x\(image.height) px to \(path)",
        ]
    }

    /// The session's recent actions with their verdicts — the same entries the popover and
    /// the bezel show, so an agent and the human are reading one record.
    private func activity() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let entries = activityLog.recent(50).map { entry -> [String: Any] in
            [
                "date": formatter.string(from: entry.date),
                "action": entry.action,
                "target": entry.target,
                "verdict": entry.verdict,
                "summary": entry.summary,
            ]
        }
        return [
            "ok": true,
            "entries": entries,
            "count": entries.count,
            "halted": EmergencyStop.isHalted,
            "summary": entries.isEmpty
                ? "no recorded actions this session"
                : "\(entries.count) recent action(s)" + (EmergencyStop.isHalted ? " · HALTED (⌃⌥⇧⎋)" : ""),
        ]
    }

    private func status() -> [String: Any] {
        let presence = UserPresence.read()
        var reply: [String: Any] = [
            "ok": true,
            "trusted": AXIsProcessTrusted(),
            "presence": presence.state.rawValue,
            "idleSeconds": Int(presence.idleSeconds),
            "screenLocked": presence.screenLocked,
            "displayAsleep": presence.displayAsleep,
            "offConsole": presence.offConsole,
            "canSee": presence.canSee,
            "mayTakeCursor": presence.mayTakeCursor,
            "advice": presence.advice,
            "virtualDisplayActive": virtualDisplay.activeLease != nil,
            "displayHold": adrafinil.isHolding ? (adrafinil.mechanism ?? "internal") : "none",
            "halted": EmergencyStop.isHalted,
        ]
        // Why the halt happened — the ⌃⌥⇧⎋ press, or a plan that paused for the human — so a
        // halted agent learns more than the generic refusal string tells it.
        if EmergencyStop.isHalted, let reason = EmergencyStop.reason {
            reply["haltReason"] = reason
        }
        return reply
    }

    /// Fires the Screen Recording prompt.
    ///
    /// ScreenCaptureKit does **not** prompt — it fails with -3801 when ungranted. Only
    /// `CGRequestScreenCaptureAccess` shows the dialog, and only while TCC holds no decision
    /// for this bundle; after a decline it returns instantly and forever. `tccutil reset
    /// ScreenCapture <bundle-id>` is what makes it askable again.
    private func requestCapture() -> [String: Any] {
        let granted = CGRequestScreenCaptureAccess()
        return [
            "ok": true,
            "granted": granted,
            "preflightAfter": ScreenCapture.isPermitted,
            "note": granted ? "granted" : "if no dialog appeared, TCC still holds a decision — reset it",
        ]
    }

    /// Reports what each permission check actually returns, and what a real capture attempt
    /// actually fails with. Guessing at TCC state from the outside is how hours get lost.
    private func diagnose() async -> [String: Any] {
        var report: [String: Any] = [
            "ok": true,
            "bundleID": Bundle.main.bundleIdentifier ?? "?",
            "bundlePath": Bundle.main.bundlePath,
            "axTrusted": AXIsProcessTrusted(),
            "screenCapturePreflight": ScreenCapture.isPermitted,
            "engineOffMainThread": await engine.runsOffMainThread(),
        ]
        do {
            let image = try await ScreenCapture.image(of: CGRect(x: 0, y: 0, width: 16, height: 16))
            report["captureAttempt"] = image == nil ? "returned nil" : "succeeded (\(image!.width)x\(image!.height) px)"
        } catch {
            report["captureAttempt"] = "threw: \(error)"
        }
        return report
    }

    /// `type` is the one verb that can destroy or send something, so its guards live here.
    private func typeCommand(_ request: Request) async throws -> [String: Any] {
        // Absent text is not the same as empty text. Defaulting to "" would silently clear the
        // field — an unrecoverable write — for a request that simply forgot an argument.
        guard let text = request.text else {
            return [
                "ok": false,
                "error": "'type' requires text; pass an empty string explicitly to clear a field",
                "presence": presenceBlock(),
            ]
        }
        // A newline in a composer submits. Refuse control characters unless asked plainly.
        if request.submit != true, text.contains(where: { $0.isNewline || $0 == "\t" }) {
            return [
                "ok": false,
                "error": "text contains a control character that would submit or move focus; pass submit:true to allow it",
                "presence": presenceBlock(),
            ]
        }
        return try await act(request, action: .setText(text))
    }

    /// Parses a comma-separated modifier list ("cmd,shift") into event flags. Unknown tokens
    /// are ignored rather than refused — a click with one modifier misspelled should still
    /// carry the ones that parsed, and the reply's evidence shows what landed.
    private static func parseModifiers(_ text: String?) -> CGEventFlags {
        guard let text else { return [] }
        var flags: CGEventFlags = []
        for token in text.lowercased().split(whereSeparator: { $0 == "," || $0 == "+" }) {
            switch token.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }

    /// The wire shape of one element: `label` is the element's own name (empty when it has
    /// none), with `roleDescription`, `help`, `identifier`, `subrole`, and `near` filling the
    /// gaps that a bare "button" label used to hide. Empty fields are omitted so a labelled
    /// control's row stays as terse as it was.
    private func elementRow(_ element: Engine.ElementDescriptor) -> [String: Any] {
        var row: [String: Any] = [
            "role": element.role,
            "label": element.label,
            "value": element.value,
            "depth": element.depth,
        ]
        if let roleDescription = element.roleDescription { row["roleDescription"] = roleDescription }
        if let help = element.help { row["help"] = help }
        if let identifier = element.identifier { row["identifier"] = identifier }
        if let subrole = element.subrole { row["subrole"] = subrole }
        if let near = element.near { row["near"] = near }
        if let frame = element.frame {
            row["frame"] = ["x": frame.x, "y": frame.y, "w": frame.width, "h": frame.height]
        }
        return row
    }

    private func find(_ request: Request) async throws -> [String: Any] {
        let pid = try resolve(request)
        // Explicit --ocr skips the tree; otherwise walk it, and fall back to OCR only when the
        // walk found nothing and Screen Recording can supply an answer — an AX-dead app then
        // reads instead of returning an empty list.
        if request.ocr == true {
            return try await visionFindReply(pid: pid, query: request.label, window: request.window)
        }
        let outcome = try await engine.find(
            pid: pid, query: request.label, role: request.role, windowTitle: request.window,
            all: request.all == true,
            limit: request.limit.map { max(Int($0), 0) } ?? 20,
            offset: request.offset.map { max(Int($0), 0) } ?? 0,
        )
        if outcome.elements.isEmpty, request.all != true, ScreenCapture.isPermitted,
           let fallback = try? await visionFindReply(pid: pid, query: request.label, window: request.window) {
            return fallback
        }
        return [
            "ok": true,
            "matches": outcome.elements.map(elementRow),
            "truncated": outcome.truncated,
            "elementsVisited": outcome.elementsVisited,
            // The page and the whole, so the 20-row cap is never a silent surprise.
            "shown": outcome.elements.count,
            "total": outcome.total,
            "offset": outcome.offset,
            "canSee": true,
            "cache": ["hits": outcome.cacheHits, "misses": outcome.cacheMisses],
            "presence": presenceBlock(),
        ]
    }

    /// `find` over vision rows: OCR text lines plus, when the detector model is installed,
    /// control boxes — each row stamped with its own `groundedBy` (`ocr` or `detector`) so the
    /// caller knows a text sighting from a proposed control. A detector control that carries no
    /// text (an icon button) still appears, with an empty label and a real frame, so it is
    /// addressable. Filtered by the query substring against the label when one is given
    /// (icon-only controls have no text to match), capped at 20 like the tree find.
    private func visionFindReply(pid: pid_t, query: String?, window: String? = nil) async throws -> [String: Any] {
        var rows = try await engine.visionRows(pid: pid, windowTitle: window)
        if let needle = query?.lowercased(), !needle.isEmpty {
            rows = rows.filter { $0.label.lowercased().contains(needle) }
        }
        let total = rows.count
        let shown = Array(rows.prefix(20))
        let usedDetector = shown.contains { $0.groundedBy == "detector" }
        return [
            "ok": true,
            "matches": shown.map { row -> [String: Any] in
                var match: [String: Any] = [
                    "role": row.role,
                    "label": row.label,
                    "value": "",
                    "depth": 0,
                    "groundedBy": row.groundedBy,
                    "frame": ["x": row.frame.x, "y": row.frame.y, "w": row.frame.width, "h": row.frame.height],
                ]
                if let confidence = row.confidence { match["confidence"] = confidence }
                return match
            },
            "truncated": total > shown.count,
            "shown": shown.count,
            "total": total,
            "elementsVisited": total,
            "groundedBy": usedDetector ? "vision" : "ocr",
            "canSee": true,
            "presence": presenceBlock(),
        ]
    }

    /// Text out of an app without pixels — the most-used observe verb. Orders of magnitude
    /// cheaper in tokens than screenshot-plus-vision, and it works behind a locked screen.
    /// With `since`, the reply is the structural delta against that earlier read — the
    /// caller pays for the change, not the window.
    private func read(_ request: Request) async throws -> [String: Any] {
        let pid = try resolve(request)
        if request.ocr == true {
            return try await visionReadReply(pid: pid, window: request.window)
        }
        let outcome = try await engine.read(
            pid: pid, label: request.label, role: request.role, since: request.since,
            windowTitle: request.window,
        )
        // An empty walk on an app that exposes no tree is exactly where OCR earns its place —
        // fall back rather than reply "nothing here" about a window full of text. Only for the
        // whole-window read, and never when a diff was requested (a `--since` diff of a full
        // window against nothing is not what OCR answers).
        if outcome.delta == nil, outcome.lines.isEmpty, request.label == nil, request.since == nil,
           ScreenCapture.isPermitted, let fallback = try? await visionReadReply(pid: pid, window: request.window) {
            return fallback
        }
        // A usable diff replaces the lines wholesale — sending both would defeat the verb.
        if let delta = outcome.delta {
            return [
                "ok": true,
                "scope": outcome.scope,
                "since": delta.since,
                "token": outcome.token,
                "changes": delta.changes,
                "delta": delta.text,
                "elementsVisited": outcome.elementsVisited,
                "summary": delta.changes == 0
                    ? "no changes in \(outcome.scope) since \(delta.since)"
                    : "\(delta.changes) change(s) in \(outcome.scope) since \(delta.since)",
                "presence": presenceBlock(),
            ]
        }
        var reply: [String: Any] = [
            "ok": true,
            "scope": outcome.scope,
            "lines": outcome.lines.map { line -> [String: Any] in
                var row: [String: Any] = ["role": line.role, "depth": line.depth]
                if !line.title.isEmpty { row["title"] = line.title }
                if !line.value.isEmpty { row["value"] = line.value }
                return row
            },
            "elementsVisited": outcome.elementsVisited,
            "characters": outcome.characters,
            "truncated": outcome.truncated,
            "token": outcome.token,
            "presence": presenceBlock(),
        ]
        if let note = outcome.diffNote { reply["diffNote"] = note }
        if let reason = outcome.truncationReason { reply["truncationReason"] = reason }
        if let referral = outcome.referral {
            reply["referral"] = [
                "channel": referral.channel,
                "reason": referral.reason,
                "advice": referral.advice,
            ]
        }
        return reply
    }

    /// `read` over vision rows: the window's on-screen text in reading order, plus control
    /// boxes when the detector model is installed, each line stamped with its own `groundedBy`
    /// (`ocr` or `detector`). The answer for a window whose accessibility tree is empty or
    /// lying — no token or delta, because there is no tree walk to diff against.
    private func visionReadReply(pid: pid_t, window: String? = nil) async throws -> [String: Any] {
        let rows = try await engine.visionRows(pid: pid, windowTitle: window)
        let usedDetector = rows.contains { $0.groundedBy == "detector" }
        let channel = usedDetector ? "vision" : "OCR"
        return [
            "ok": true,
            "scope": window.map { "window '\($0)' (\(channel))" } ?? "window (\(channel))",
            "groundedBy": usedDetector ? "vision" : "ocr",
            "lines": rows.map { row -> [String: Any] in
                var line: [String: Any] = [
                    "role": row.role,
                    "depth": 0,
                    "groundedBy": row.groundedBy,
                    "frame": ["x": row.frame.x, "y": row.frame.y, "w": row.frame.width, "h": row.frame.height],
                ]
                if !row.label.isEmpty { line["value"] = row.label }
                if let confidence = row.confidence { line["confidence"] = confidence }
                return line
            },
            "characters": rows.reduce(0) { $0 + $1.label.count },
            "elementsVisited": rows.count,
            "truncated": false,
            "presence": presenceBlock(),
        ]
    }

    /// The running apps a human would recognize as running — regular activation policy, the
    /// set the Dock and the ⌘-Tab switcher show.
    private func apps() -> [String: Any] {
        let rows = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { application -> [String: Any] in
                var row: [String: Any] = [
                    "name": application.localizedName ?? "?",
                    "bundleID": application.bundleIdentifier ?? "?",
                    "pid": application.processIdentifier,
                    "frontmost": application.isActive,
                    "hidden": application.isHidden,
                ]
                // Start time and bundle path distinguish two instances of one bundle id — the
                // pid alone was a coin flip that killed the wrong app once.
                if let started = application.launchDate {
                    row["launchedAt"] = ISO8601DateFormatter().string(from: started)
                }
                if let path = application.bundleURL?.path { row["bundlePath"] = path }
                return row
            }
            .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        return [
            "ok": true,
            "apps": rows,
            "count": rows.count,
            "summary": "\(rows.count) apps running",
            "presence": presenceBlock(),
        ]
    }

    private func windows(_ request: Request) async throws -> [String: Any] {
        let pid = try resolve(request)
        let list = try await engine.windowList(pid: pid)
        let displays = virtualDisplay.displayBounds
        let virtualBounds = virtualDisplay.virtualScreenBounds
        var strays = 0
        let rows = list.map { window -> [String: Any] in
            var row: [String: Any] = [
                "title": window.title,
                "minimized": window.minimized,
                "main": window.isMain,
            ]
            if let frame = window.frame {
                row["frame"] = block(for: frame)
                let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                if let display = displays.first(where: { $0.contains(center) }) {
                    row["display"] = block(for: display)
                    let onVirtual = display == virtualBounds
                    row["onVirtualDisplay"] = onVirtual
                    // On the virtual display without being in the parked set: nobody put it
                    // there, so nobody will sweep it home — the invisible-window hazard.
                    if onVirtual, !virtualDisplay.isParked(pid: pid, title: window.title) {
                        row["stray"] = true
                        strays += 1
                    }
                } else {
                    // A window whose center is on no display is exactly the stranding the
                    // park lease rules exist to prevent — say so rather than omitting it.
                    row["onAnyDisplay"] = false
                }
            }
            return row
        }
        return [
            "ok": true,
            "windows": rows,
            "count": rows.count,
            "strays": strays,
            "summary": "\(rows.count) window(s)"
                + (strays > 0 ? " · \(strays) stray(s) on the virtual display" : ""),
            "presence": presenceBlock(),
        ]
    }

    private func act(_ request: Request, action: GhostReach.Action) async throws -> [String: Any] {
        let pid = try resolve(request)
        // A coordinate is answered by a hit-test and a label by a search; neither falls back to
        // the other, so the caller always knows which mechanism replied.
        let locator: Engine.Locator = if let x = request.x, let y = request.y {
            .point(x: x, y: y)
        } else if let label = request.label {
            .named(label, role: request.role, window: request.window)
        } else {
            .focused
        }

        var clickOptions = GhostReach.ClickOptions()
        if request.button == "right" { clickOptions.button = .right }
        if let count = request.count { clickOptions.count = min(max(Int(count), 1), 3) }
        clickOptions.modifiers = Self.parseModifiers(request.modifiers)

        isDriving = true
        defer { isDriving = false }
        let evidence = try await engine.act(
            pid: pid, locator: locator, action: action,
            allowHardwareInput: request.allowHardwareInput ?? false,
            observe: request.observe ?? false,
            clickOptions: clickOptions,
        )
        return evidenceReply(evidence)
    }

    /// Scrolls a scroll area: `to` positions absolutely via the scroll bar (read back as
    /// evidence), `dy`/`dx` post wheel events and let the bar or pixels testify.
    private func scroll(_ request: Request) async throws -> [String: Any] {
        guard request.to != nil || request.dx != nil || request.dy != nil || request.untilText != nil
            || request.label != nil else {
            return [
                "ok": false,
                "error": "'scroll' requires --label <element> (AXScrollToVisible — the one cursor-free scroll), --dy/--dx (pixels; positive dy reveals content below), --to (0=top … 1=bottom), or --until-text <string> (OCR each step, stop on sight)",
                "presence": presenceBlock(),
            ]
        }
        if let to = request.to {
            guard to.isFinite, (0.0 ... 1.0).contains(to) else {
                return ["ok": false, "error": "'to' must be between 0 (top) and 1 (bottom)"]
            }
        }
        for (name, value) in [("dx", request.dx), ("dy", request.dy)] where value != nil {
            guard let value, value.isFinite, abs(value) <= Bounds.extent else {
                return ["ok": false, "error": "'\(name)' must be a finite pixel delta within ±\(Int(Bounds.extent))"]
            }
        }
        let pid = try resolve(request)

        isDriving = true
        defer { isDriving = false }

        // The OCR loop: capture → look → step → repeat, stopping the moment the string is
        // legible. Deterministic where a pixel delta over- or undershoots blindly.
        if let needle = request.untilText {
            guard !needle.trimmingCharacters(in: .whitespaces).isEmpty else {
                return ["ok": false, "error": "'untilText' must be a non-empty string to look for"]
            }
            let search = try await engine.scrollUntilText(
                pid: pid,
                label: request.label,
                role: request.role,
                needle: needle,
                deltaY: request.dy ?? 1,
                maxSteps: Constants.maximumScrollSearchSteps,
            )
            var reply = evidenceReply(search.evidence)
            reply["steps"] = search.steps
            if let before = search.barBefore { reply["scrollbarBefore"] = before }
            if let after = search.barAfter { reply["scrollbarAfter"] = after }
            if let found = search.foundAt {
                // The sighting's screen rectangle: `click --x --y` at its center is the
                // follow-up this exists for.
                reply["foundAt"] = block(for: found)
            }
            if search.callAgain { reply["callAgain"] = true }
            return reply
        }

        let result = try await engine.scroll(
            pid: pid,
            label: request.label,
            role: request.role,
            deltaX: request.dx ?? 0,
            deltaY: request.dy ?? 0,
            toFraction: request.to,
        )
        var reply = evidenceReply(result.evidence)
        if let before = result.barBefore { reply["scrollbarBefore"] = before }
        if let after = result.barAfter { reply["scrollbarAfter"] = after }
        return reply
    }

    /// Delivers a keyboard shortcut by pressing its menu item — no CGEvent, no focus change,
    /// and it works on Chromium, which ignores keycode-only posted events entirely.
    private func shortcut(_ request: Request) async throws -> [String: Any] {
        guard let keys = request.keys else {
            return [
                "ok": false,
                "error": "'shortcut' requires --keys, e.g. --keys cmd+a",
                "presence": presenceBlock(),
            ]
        }
        let pid = try resolve(request)
        let mode: Engine.ShortcutMode = if request.resolveOnly == true {
            .resolveOnly
        } else if request.confirm == true {
            .pressConfirmed
        } else {
            .press
        }

        isDriving = true
        defer { isDriving = false }
        let result = try await engine.pressShortcut(pid: pid, keys: keys, mode: mode, observe: request.observe ?? false)
        return menuPressReply(result, resolving: "'\(keys)'")
    }

    /// Presses an arbitrary menu item by title path — the way to reach everything that has no
    /// shortcut. Same rails as `shortcut`: hazards refuse without `confirm`, `resolveOnly`
    /// audits before acting, and the enabled-state caveats carry over verbatim.
    private func menu(_ request: Request) async throws -> [String: Any] {
        guard let path = request.path else {
            return [
                "ok": false,
                "error": "'menu' requires --path, e.g. --path \"File > Export\" ('▸' works too)",
                "presence": presenceBlock(),
            ]
        }
        let pid = try resolve(request)
        let mode: Engine.ShortcutMode = if request.resolveOnly == true {
            .resolveOnly
        } else if request.confirm == true {
            .pressConfirmed
        } else {
            .press
        }

        isDriving = true
        defer { isDriving = false }
        let result = try await engine.pressMenuPath(pid: pid, path: path, mode: mode, observe: request.observe ?? false)
        return menuPressReply(result, resolving: "'\(path)'")
    }

    /// Posts a bare named key (Escape, Return, arrows…) with optional modifiers. The gap the
    /// other input verbs leave: `type` is text-only and `shortcut` only reaches keys that a
    /// menu item carries — a file-picker dialog's Escape is neither.
    ///
    /// With `allowHardwareInput` the key is pressed on the console pipeline instead of
    /// posted per-pid — the only channel that reaches key-equivalent dispatch (sheet
    /// Escape, default-button Return). It lands in global focus like any human keypress,
    /// so it is gated like the other hardware verbs and additionally requires the target
    /// to be frontmost: a session keystroke aimed at a background app would land in
    /// whatever the human is actually using.
    private func key(_ request: Request) async throws -> [String: Any] {
        guard let keys = request.keys else {
            return [
                "ok": false,
                "error": "'key' requires --keys, e.g. --keys escape or --keys shift+tab",
                "presence": presenceBlock(),
            ]
        }
        let pid = try resolve(request)

        var delivery: Engine.KeyDelivery = .process
        if request.allowHardwareInput == true {
            let presence = UserPresence.read()
            guard !presence.lockBlocksHardware else {
                return [
                    "ok": false,
                    "error": "the screen is locked — a console keystroke would land in the login window's password field",
                    "presence": presenceBlock(),
                ]
            }
            guard await consented(
                prompt: "Send a session-level key press to the front app",
                detail: "\(Self.target(of: request)) · key",
                away: presence.state == .away, confirm: request.confirm == true,
            ) else {
                return declinedReply("The session key")
            }
            let frontmostPid = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            guard frontmostPid == pid else {
                return [
                    "ok": false,
                    "error": "the target is not frontmost — a session-level key would land in the frontmost app "
                        + "instead. Activate the target first, or use the per-pid form (drop allowHardwareInput).",
                    "presence": presenceBlock(),
                ]
            }
            delivery = .session
        }

        isDriving = true
        defer { isDriving = false }
        let evidence = try await engine.pressKey(pid: pid, keys: keys, delivery: delivery)
        return evidenceReply(evidence)
    }

    /// A disruptive action wants to run while a human may be at the machine. `away` (nobody
    /// here) or a caller that already carries the human's authority via `--confirm` proceeds
    /// without asking. Otherwise the overlay puts the decision to the human — a one-second hold
    /// on Y or N — and this blocks on it; the socket call waits with it, and a timeout is a no.
    private func consented(prompt: String, detail: String, away: Bool, confirm: Bool) async -> Bool {
        if away || confirm { return true }
        return await overlay.requestConsent(prompt: prompt, detail: detail)
    }

    /// The refusal a declined (or unanswered) consent returns — the same shape as the old
    /// `--confirm` refusal, so a caller that was ready to hear "pass confirm" still gets a
    /// clean `ok:false` it can reason about.
    private func declinedReply(_ what: String) -> [String: Any] {
        [
            "ok": false,
            "error": "\(what) was declined by the human at the machine (held N, or no answer in time).",
            "presence": presenceBlock(),
        ]
    }

    /// `move` (hover, glide) and `drag` (button held along the path) — the cursor-path
    /// verbs. Hardware-tentacle by measurement: per-pid posted motion is dropped wholesale by
    /// the window server (cursor-paths experiment, 2026-08-20), so these take the real
    /// cursor, and they are presence-gated exactly like `activate`.
    private func trace(_ request: Request, dragging: Bool) async throws -> [String: Any] {
        let verb = dragging ? "drag" : "move"
        let presence = UserPresence.read()
        guard !presence.lockBlocksHardware else {
            return [
                "ok": false,
                "error": "the screen is locked — the cursor belongs to the login window right now",
                "presence": presenceBlock(),
            ]
        }
        guard await consented(
            prompt: "\(dragging ? "Drag" : "Move") the real cursor across the screen",
            detail: "\(Self.target(of: request)) · \(verb)",
            away: presence.state == .away, confirm: request.confirm == true,
        ) else {
            return declinedReply("The \(verb)")
        }

        func parsePoint(_ text: String, flag: String) throws -> CGPoint {
            let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let x = parts[0], let y = parts[1],
                  Self.finite(x, limit: Bounds.coordinate) != nil,
                  Self.finite(y, limit: Bounds.coordinate) != nil else {
                throw Engine.EngineError.pathRefused("'--\(flag)' must be a finite \"x,y\" point, got '\(text)'")
            }
            return CGPoint(x: x, y: y)
        }

        var waypoints: [CGPoint] = []
        if let start = request.start { waypoints.append(try parsePoint(start, flag: "from")) }
        if dragging, waypoints.isEmpty {
            return [
                "ok": false,
                "error": "'drag' requires --from x,y — a drag from \"wherever the cursor happens to be\" presses the button somewhere the caller never chose",
                "presence": presenceBlock(),
            ]
        }
        for pair in (request.via ?? "").split(whereSeparator: { $0 == " " || $0 == ";" }) {
            waypoints.append(try parsePoint(String(pair), flag: "via"))
        }
        if let end = request.end { waypoints.append(try parsePoint(end, flag: "to")) }
        guard request.end != nil || request.label != nil else {
            return [
                "ok": false,
                "error": "'\(verb)' needs a destination: --to x,y, or --label <text> (with --app) to aim at an element",
                "presence": presenceBlock(),
            ]
        }

        var easing = PathPlan.Easing.easeInOut
        if let name = request.easing {
            guard let parsed = PathPlan.Easing(rawValue: name) else {
                return [
                    "ok": false,
                    "error": "unknown easing '\(name)' — one of: \(PathPlan.Easing.allCases.map(\.rawValue).joined(separator: ", "))",
                    "presence": presenceBlock(),
                ]
            }
            easing = parsed
        }
        var duration: Duration?
        if let seconds = request.duration {
            guard seconds.isFinite, (0.05 ... 10).contains(seconds) else {
                return [
                    "ok": false,
                    "error": "'duration' is in seconds, 0.05–10 — the control socket cancels requests at 30",
                    "presence": presenceBlock(),
                ]
            }
            duration = .seconds(seconds)
        }
        var button: HardwareInput.MouseButton?
        if dragging {
            button = HardwareInput.MouseButton(rawValue: request.button ?? "left")
            guard button != nil else {
                return ["ok": false, "error": "'button' is left or right", "presence": presenceBlock()]
            }
        }
        let pid: pid_t? = request.app != nil ? try resolve(request) : nil

        // drag/move already take the cursor — ensuring the target is frontmost and its
        // window is key is part of the same contract, not a separate escalation. Without
        // this the first mouseDown is swallowed as an "activating click" and the drag
        // draws on nothing.
        if let pid {
            let targetBundle = await MainActor.run {
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
            let frontBundle = await MainActor.run { EventPoster.frontmostBundleID }
            if frontBundle != targetBundle {
                await MainActor.run {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                }
                try? await Task.sleep(for: .milliseconds(200))
                // The first click after activation is swallowed as an activating click
                // by AppKit/WebKit — post one to absorb it so the drag's own mouseDown
                // reaches the content. Only needed when we just activated.
                if dragging, let startPoint = waypoints.first {
                    await EventPoster.click(at: startPoint, pid: pid)
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
        }

        isDriving = true
        defer { isDriving = false }
        let result = try await engine.trace(
            pid: pid,
            waypoints: waypoints,
            label: request.label,
            role: request.role,
            duration: duration,
            easing: easing,
            button: button,
            restoreCursor: request.restore == true,
            windowTitle: request.window,
            // Clamped: the socket cancels at 30 s, and a tooltip needs at most a second or two.
            dwell: request.dwell.map { .milliseconds(min(max(Int($0), 0), 5000)) },
        )

        // The read-back is the system's own cursor position: the gesture is confirmed when
        // the pointer provably stands at the planned destination (or back home after a
        // requested restore). What the motion *caused* is reported alongside — window-count
        // deltas catch the flyout/menu family that element evidence is blind to.
        let outcome = result.outcome
        let landed = request.restore == true || hypot(
            outcome.cursorEnd.x - result.plannedEnd.x,
            outcome.cursorEnd.y - result.plannedEnd.y,
        ) <= 3
        let verdict: String = if outcome.abortReason != nil {
            "unverifiable"
        } else if landed {
            "confirmed"
        } else {
            "unverifiable"
        }
        var summary = if let abort = outcome.abortReason {
            "\(verb) stopped after \(outcome.samplesPosted)/\(outcome.samplesTotal) samples — \(abort)"
        } else if landed {
            "\(dragging ? "dragged" : "moved") \(Int(result.pathLength))pt along \(result.sampleCount) samples in \(String(format: "%.2f", result.durationSeconds))s"
                + (request.restore == true ? ", cursor restored" : "; cursor now at (\(Int(outcome.cursorEnd.x)), \(Int(outcome.cursorEnd.y)))")
        } else {
            "\(verb) completed but the cursor reads (\(Int(outcome.cursorEnd.x)), \(Int(outcome.cursorEnd.y))), not the planned (\(Int(result.plannedEnd.x)), \(Int(result.plannedEnd.y))) — a human hand may be on the mouse"
        }
        if let before = result.windowsBefore, let after = result.windowsAfter, after != before {
            summary += " · target windows \(before) → \(after)"
        }
        if let changes = result.treeChanges {
            summary += " · revealed \(changes) tree change(s)"
        }

        var reply: [String: Any] = [
            "ok": outcome.abortReason == nil && landed,
            "verdict": verdict,
            "tentacle": "hardwareInput",
            "summary": summary,
            "cursorMoved": true,
            "cursorMovedByUs": true,
            "plannedEnd": ["x": result.plannedEnd.x, "y": result.plannedEnd.y],
            "cursorEnd": ["x": outcome.cursorEnd.x, "y": outcome.cursorEnd.y],
            "samples": outcome.samplesPosted,
            "pathLength": (result.pathLength * 10).rounded() / 10,
            "durationSeconds": (result.durationSeconds * 100).rounded() / 100,
            "presence": presenceBlock(),
        ]
        if let abort = outcome.abortReason { reply["aborted"] = abort }
        if let before = result.windowsBefore, let after = result.windowsAfter {
            reply["targetWindowsBefore"] = before
            reply["targetWindowsAfter"] = after
        }
        if let owner = result.endpointOwner { reply["windowUnderCursorOwnedBy"] = owner }
        // What the hover revealed — the tooltip or flyout that the tree diff caught.
        if let changes = result.treeChanges { reply["treeChanges"] = changes }
        if let delta = result.treeDelta { reply["treeDelta"] = delta }
        if let pid, !dragging {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmost != pid {
                // Measured asymmetry, worth telling the caller every time: AppKit tracking
                // areas fire on background windows, WebKit web content drops all motion
                // until the app is frontmost.
                reply["note"] = "the target app is not frontmost — AppKit hover fires anyway, but "
                    + "WebKit/WKWebView content ignores motion in inactive windows; 'activate' first "
                    + "if a web page's hover state does not take"
            }
        }
        return reply
    }

    /// The shared back half of `shortcut` and `menu` — one press mechanism, one reply shape.
    private func menuPressReply(_ result: Engine.MenuPressResult, resolving: String) -> [String: Any] {
        guard let evidence = result.evidence else {
            // Resolve-only: what would be pressed, without pressing it.
            var reply: [String: Any] = [
                "ok": true,
                "menuItem": result.menuPath,
                "enabled": result.itemReportedEnabled,
                "summary": "\(resolving) resolves to '\(result.menuPath)' (not pressed)",
                "presence": presenceBlock(),
            ]
            if let hazard = result.hazard {
                reply["hazard"] = hazard
                reply["requiresConfirm"] = true
            }
            return reply
        }

        var reply = evidenceReply(evidence)
        reply["menuItem"] = result.menuPath
        if let hazard = result.hazard { reply["hazard"] = hazard }
        if !result.itemReportedEnabled {
            // Measured both ways on 2026-08-02: a background AppKit app (TextEdit) reports
            // disabled and the press is a silent no-op that still returns success; a
            // background Electron app (Postman) reports enabled and the press works.
            reply["menuItemReportedDisabled"] = true
            reply["note"] = "the menu item reported disabled before the press. On AppKit apps "
                + "in the background this is accurate — the press returns success but does "
                + "nothing, because inactive apps never validate their menus. Treat anything "
                + "short of a confirmed verdict as 'did not happen'; activating the target "
                + "first is what makes AppKit menus live."
        }
        return reply
    }

    /// Blocks until an element appears (or disappears). The cap exists because the control
    /// socket cancels requests at 30 s; rather than racing that timeout and losing, the verb
    /// stays under it and tells the caller to loop.
    private func wait(_ request: Request) async throws -> [String: Any] {
        guard request.label != nil || request.expect != nil else {
            return [
                "ok": false,
                "error": "'wait' requires --label <text> to watch for, or --for '<guard json>' "
                    + "(window-appears/window-vanishes/text-visible/text-vanishes/quiet/token-changed)",
                "presence": presenceBlock(),
            ]
        }
        let seconds = request.timeout ?? Constants.defaultWaitSeconds
        guard seconds > 0, seconds <= Constants.maximumWaitSeconds else {
            return [
                "ok": false,
                "error": "'timeout' must be 1–\(Int(Constants.maximumWaitSeconds)) seconds — the control socket "
                    + "cancels requests at 30. For longer waits, call again when the reply says callAgain.",
                "presence": presenceBlock(),
            ]
        }
        // The guard grammar, when given. `--app` is optional for it — only the state guards
        // need a pid, and they report honestly when none resolved.
        if let predicate = request.expect {
            let pid = resolvePid(request)
            let outcome = try await engine.waitForGuard(
                pid: pid, guard: predicate, timeout: .seconds(seconds),
            )
            return [
                "ok": outcome.satisfied,
                "satisfied": outcome.satisfied,
                "callAgain": !outcome.satisfied,
                "elapsedSeconds": (outcome.elapsedSeconds * 10).rounded() / 10,
                "polls": outcome.polls,
                "summary": outcome.satisfied
                    ? "\(outcome.reason) after \(String(format: "%.1f", outcome.elapsedSeconds))s"
                    : "timed out after \(Int(seconds))s — \(outcome.reason); call again to keep waiting",
                "presence": presenceBlock(),
            ]
        }
        let label = request.label!
        let pid = try resolve(request)
        let gone = request.gone == true
        let outcome = try await engine.waitFor(
            pid: pid, label: label, role: request.role, gone: gone, timeout: .seconds(seconds),
            windowTitle: request.window,
        )
        return [
            // ok mirrors the condition so scripts can branch on the exit code directly.
            "ok": outcome.satisfied,
            "satisfied": outcome.satisfied,
            "callAgain": !outcome.satisfied,
            "elapsedSeconds": (outcome.elapsedSeconds * 10).rounded() / 10,
            "polls": outcome.polls,
            "matches": outcome.matches.map { ["role": $0.role, "label": $0.label] },
            "summary": outcome.satisfied
                ? "'\(label)' \(gone ? "gone" : "present") after \(String(format: "%.1f", outcome.elapsedSeconds))s"
                : "timed out after \(Int(seconds))s — '\(label)' still \(gone ? "present" : "absent"); call again to keep waiting",
            "presence": presenceBlock(),
        ]
    }

    /// Launches an app without stealing focus and waits until it can actually be driven.
    /// "The process started" and "you can send it commands" are different claims; the reply
    /// only says ready once the accessibility tree answers.
    private func launch(_ request: Request) async throws -> [String: Any] {
        guard let name = request.app else { throw RouterError.missingApp }

        if let pid = try? resolve(request) {
            let readiness = await engine.waitUntilDrivable(pid: pid, timeout: .seconds(Constants.relaunchReadySeconds))
            return [
                "ok": true,
                "pid": pid,
                "alreadyRunning": true,
                "ready": readiness.ready,
                "windows": readiness.windows,
                "summary": readiness.ready
                    ? "'\(name)' was already running and is drivable (\(readiness.windows) window(s))"
                    : "'\(name)' is running but its accessibility tree is not answering",
                "presence": presenceBlock(),
            ]
        }

        guard let url = applicationURL(named: name) else {
            return [
                "ok": false,
                "error": "no app named '\(name)' found — tried /Applications, /System/Applications, "
                    + "~/Applications, and bundle-id lookup. Pass a full path to launch from elsewhere.",
                "presence": presenceBlock(),
            ]
        }
        // `activates = false` keeps the launch itself ghost-safe, but it cannot keep the app's
        // first window off the human's Space — and when the frontmost app is fullscreen, that
        // window arriving is what switches Spaces and throws them out of it. Refuse rather than
        // do it silently; `park` puts the new window on the virtual display instead.
        let presence = UserPresence.read()
        if Foreground.frontmostIsFullscreen, presence.state != .away, request.confirm != true {
            return [
                "ok": false,
                "error": "'\(Foreground.frontmostName)' is fullscreen — a launching app's first "
                    + "window would switch Spaces and pull the human out of it. Park the target on "
                    + "the virtual display, or pass confirm:true if that is genuinely intended.",
                "presence": presenceBlock(),
            ]
        }

        let configuration = NSWorkspace.OpenConfiguration()
        // Ghost discipline: launching must not steal focus any more than typing does.
        configuration.activates = false
        let application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        let pid = application.processIdentifier

        isDriving = true
        defer { isDriving = false }
        let readiness = await engine.waitUntilDrivable(pid: pid, timeout: .seconds(Constants.launchReadySeconds))
        return [
            "ok": readiness.ready,
            "pid": pid,
            "alreadyRunning": false,
            "ready": readiness.ready,
            "windows": readiness.windows,
            "elapsedSeconds": (readiness.elapsedSeconds * 10).rounded() / 10,
            "summary": readiness.ready
                ? "'\(name)' is running and drivable (\(readiness.windows) window(s), \(String(format: "%.1f", readiness.elapsedSeconds))s)"
                : "'\(name)' launched but its accessibility tree has not answered after \(Int(readiness.elapsedSeconds))s — it may still be starting; check with 'windows'",
            "presence": presenceBlock(),
        ]
    }

    /// Brings an app to the foreground — deliberately, as a named verb, because sometimes
    /// that is the honest option (background AppKit menus never validate). Taking focus is
    /// the one thing the ghost tentacles promise never to do, so doing it on purpose is
    /// presence-gated exactly like hardware input.
    private func activate(_ request: Request) async throws -> [String: Any] {
        let pid = try resolve(request)
        let presence = UserPresence.read()
        guard await consented(
            prompt: "Bring \(Self.target(of: request)) to the front",
            detail: "\(Self.target(of: request)) · activate",
            away: presence.state == .away, confirm: request.confirm == true,
        ) else {
            return declinedReply("Activating \(Self.target(of: request))")
        }
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            throw RouterError.appNotRunning(request.app ?? "?")
        }

        isDriving = true
        defer { isDriving = false }
        application.activate()
        try? await Task.sleep(for: .milliseconds(500))
        // Read-back, not the call's return: whether the target actually came forward.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let landed = frontmost?.processIdentifier == pid
        return [
            "ok": landed,
            "frontmost": frontmost?.localizedName ?? "?",
            "focusTakenByUs": landed,
            "summary": landed
                ? "'\(application.localizedName ?? "?")' is frontmost and holds focus"
                : "activate did not land — '\(frontmost?.localizedName ?? "?")' is still frontmost",
            "presence": presenceBlock(),
        ]
    }

    /// Where an app by this name lives. Deliberately predictable rather than clever: the
    /// standard directories, then bundle-id lookup, then an explicit path.
    private func applicationURL(named name: String) -> URL? {
        if name.contains("/") {
            let url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let directories = [
            "/Applications", "/Applications/Utilities",
            "/System/Applications", "/System/Applications/Utilities",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appending(path: "\(name).app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
    }

    private func evidenceReply(_ evidence: Evidence) -> [String: Any] {
        var reply: [String: Any] = [
            "ok": evidence.succeeded,
            "verdict": evidence.verdict.rawValue,
            "tentacle": evidence.tentacle.rawValue,
            "summary": evidence.summary,
            "readback": evidence.readback ?? "",
            "cursorMoved": evidence.cursorMoved,
            "cursorMovedByUs": evidence.cursorMovedByUs,
            "cursorMovedByUser": evidence.cursorMovedByUser,
            "frontmostChanged": evidence.frontmostChanged,
            "focusTakenByUs": evidence.focusTakenByUs,
            "attempts": evidence.attempts.map { ["tentacle": $0.tentacle.rawValue, "outcome": $0.outcome] },
            "presence": presenceBlock(),
        ]
        // The measurement behind a visual verdict. Exposing it is what makes a wrong
        // threshold discoverable from outside instead of reading as a mystery no-effect.
        if let pixelDelta = evidence.pixelDelta { reply["pixelDelta"] = pixelDelta }
        if let suggestion = evidence.suggestion { reply["suggestion"] = suggestion }
        // Coordinates that came from pixels rather than the tree are less certain; the
        // caller's cue to verify with a diff before building on them.
        if let groundedBy = evidence.groundedBy { reply["groundedBy"] = groundedBy }
        // The tree-delta channel: how many elements moved, and (when any did) the rendered
        // diff — the reply's most legible account of what the action caused.
        if let treeChanges = evidence.treeChanges { reply["treeChanges"] = treeChanges }
        if let treeDelta = evidence.treeDelta { reply["treeDelta"] = treeDelta }
        if let referral = evidence.referral {
            reply["referral"] = [
                "channel": referral.channel,
                "reason": referral.reason,
                "advice": referral.advice,
            ]
        }
        return reply
    }

    // MARK: - Virtual display

    /// Lease lifecycle over the socket. Explicit leases stay first-class; `park` may also
    /// take an *auto* lease as a recorded, traceable side effect (reason auto-filled from
    /// the command, id in the park reply) — the load-bearing guarantee was always that a
    /// virtual screen is traceable to a lease's recorded reason, not the two-step ceremony.
    private func display(_ request: Request) async throws -> [String: Any] {
        switch request.action {
        case "acquire":
            let lease: VirtualDisplayBridge.Lease
            if let minutes = request.minutes, minutes > 0 {
                lease = try virtualDisplay.acquire(
                    reason: request.reason ?? "socket client",
                    duration: .seconds(minutes * 60),
                )
            } else {
                lease = try virtualDisplay.acquire(reason: request.reason ?? "socket client")
            }
            var reply: [String: Any] = [
                "ok": true,
                "lease": lease.id.uuidString,
                "summary": "virtual display leased (\(lease.reason))",
            ]
            if let bounds = virtualDisplay.virtualScreenBounds { reply["screen"] = block(for: bounds) }
            return reply

        case "release":
            guard let leaseArgument = request.lease else {
                // No id given: release every lease at once and sweep the display clean — the
                // deliberate reset for when nothing else is going to release them.
                let count = virtualDisplay.leases.count
                await virtualDisplay.releaseAll()
                return [
                    "ok": true,
                    "leasesRemaining": 0,
                    "summary": count > 0
                        ? "released all \(count) lease(s); display torn down and windows swept home"
                        : "no outstanding leases to release",
                ]
            }
            guard let id = UUID(uuidString: leaseArgument) else {
                return ["ok": false, "error": "'display release --lease' needs a valid lease id from acquire (or omit --lease to release all)"]
            }
            guard let outcome = await virtualDisplay.release(id: id) else {
                return ["ok": false, "error": "no outstanding lease \(id.uuidString) — already released or expired"]
            }
            var pieces = [outcome.holdersRemaining == 0
                ? "released; no holders remain" + (outcome.tornDown ? ", display torn down" : "")
                : "released; \(outcome.holdersRemaining) other holder(s) keep the display up"]
            if outcome.sweptParked > 0 { pieces.append("\(outcome.sweptParked) parked window(s) swept home") }
            if outcome.sweptStrays > 0 {
                pieces.append("WARNING: \(outcome.sweptStrays) stray window(s) nobody parked were on the display — swept to the main screen")
            }
            var reply: [String: Any] = [
                "ok": true,
                "leasesRemaining": outcome.holdersRemaining,
                "sweptParked": outcome.sweptParked,
                "summary": pieces.joined(separator: " · "),
            ]
            if outcome.sweptStrays > 0 { reply["sweptStrays"] = outcome.sweptStrays }
            return reply

        case "status", nil:
            let strays = await virtualDisplay.strays()
            var reply: [String: Any] = [
                "ok": true,
                "attached": virtualDisplay.isAttached,
                "leases": virtualDisplay.leases.values.map { lease -> [String: Any] in
                    [
                        "id": lease.id.uuidString,
                        "reason": lease.reason,
                        "kind": lease.kind.rawValue,
                        "parkedWindows": virtualDisplay.ledger.entries(under: lease.id).count,
                        // How long until this lease auto-expires and releases itself.
                        "expiresInSeconds": max(
                            0, Int(ContinuousClock().now.duration(to: lease.expiresAt).components.seconds),
                        ),
                    ]
                },
                "parked": virtualDisplay.ledger.entries.map { entry -> [String: Any] in
                    ["pid": entry.window.pid, "title": entry.window.title]
                },
                "strays": strays.map { ["pid": $0.pid, "app": $0.app, "title": $0.title] },
                "summary": virtualDisplay.isAttached
                    ? "attached · \(virtualDisplay.leases.count) lease(s) · \(virtualDisplay.ledger.entries.count) parked"
                        + (strays.isEmpty ? "" : " · \(strays.count) STRAY window(s) nobody parked")
                    : "no virtual display",
            ]
            if let bounds = virtualDisplay.virtualScreenBounds { reply["screen"] = block(for: bounds) }
            return reply

        default:
            return ["ok": false, "error": "unknown display action '\(request.action ?? "")' — use acquire, release, or status"]
        }
    }

    // MARK: - Sequence plans

    private func plan(_ request: Request) async throws -> [String: Any] {
        guard let steps = request.steps, !steps.isEmpty else {
            return ["ok": false, "error": "'plan' requires 'steps' — a JSON array of command steps"]
        }
        let profile: SequencePlan.Profile
        if let raw = request.profile {
            guard let parsed = SequencePlan.Profile(rawValue: raw) else {
                return ["ok": false, "error": "unknown profile '\(raw)' — use ghost or visible"]
            }
            profile = parsed
        } else {
            profile = .ghost
        }
        let plan = SequencePlan(profile: profile, steps: steps)
        let executor = PlanExecutor(
            dispatch: { [weak self] req in
                guard let self else { return ["ok": false, "error": "router deallocated"] }
                if EmergencyStop.isHalted {
                    return ["ok": false, "error": EmergencyStop.refusalMessage, "halted": true]
                }
                self.adrafinil.noteActivity()
                return try await self.dispatch(req)
            },
            resolvePid: { [weak self] req in self?.resolvePid(req) },
            engine: engine,
            overlay: profile == .visible ? overlay : nil,
            activityLog: activityLog,
        )
        planExecutor = executor
        defer { planExecutor = nil }
        return await executor.execute(plan)
    }

    /// Moves an app's primary window — onto the virtual display by default, or to an explicit
    /// point (which is also how a caller puts a window back where it found it: `park` replies
    /// carry the window's previous position).
    ///
    /// Parking with no lease in force takes an **auto** lease (reason filled from the
    /// command, id in the reply, visible in `display status`), which releases itself when
    /// its last parked window is returned or closes. Attach needs no presence gate:
    /// creating a `CGVirtualDisplay` is visually silent on the real screen (measured
    /// 2026-08-24 with a present observer — no flash, no reflow), and the lease is
    /// already traceable through its recorded reason, `display status`, and the menu bar.
    private func park(_ request: Request) async throws -> [String: Any] {
        let pid = try resolve(request)
        if let x = request.x, let y = request.y {
            // A window sent where no display reaches is findable only by reading the `before`
            // block out of this reply — recoverable, but only if someone kept it. Refuse
            // instead: an explicit destination should be somewhere the window can be seen.
            let point = CGPoint(x: x, y: y)
            // `CGDisplayBounds`, not `NSScreen.frame`: park's coordinates are the top-left
            // global space AX frames use, while `NSScreen` reports bottom-left Cocoa space.
            // Comparing across the two is the coordinate trap this codebase keeps stepping
            // around, and here it would reject valid points on any non-primary display.
            let screens = virtualDisplay.displayBounds
            guard screens.contains(where: { $0.insetBy(dx: -40, dy: -40).contains(point) }) else {
                return [
                    "ok": false,
                    "error": "(\(Int(x)), \(Int(y))) is not on any display — the window would be unreachable. "
                        + "Displays currently span: "
                        + screens.map { "(\(Int($0.minX)),\(Int($0.minY))) \(Int($0.width))×\(Int($0.height))" }
                        .joined(separator: ", "),
                ]
            }
            isDriving = true
            defer { isDriving = false }
            let move = try await engine.moveWindow(pid: pid, windowTitle: request.window, to: point)
            var reply = parkReply(for: move)
            // Moving a parked window back off the virtual display is the un-park: it
            // decrements the auto-lease that parked it, which self-releases when drained.
            if move.landed, virtualDisplay.virtualScreenBounds?.contains(point) != true,
               virtualDisplay.isParked(pid: pid, title: move.window) {
                let released = await virtualDisplay.recordUnpark(pid: pid, title: move.window)
                reply["unparked"] = true
                if let released {
                    reply["leaseReleased"] = released.uuidString
                    reply["summary"] = "\(reply["summary"] ?? "") · last parked window returned, auto-lease released"
                }
            }
            return reply
        }

        // Parking onto the virtual screen happens under a lease, always: without one, a
        // window can be moved onto a display nobody is keeping alive — and when it goes,
        // the window is stranded somewhere its owner cannot see or reach. Found by doing
        // exactly that to a real Finder window. With no lease in force, park takes one out
        // itself and reports it.
        var autoLease: VirtualDisplayBridge.Lease?
        if virtualDisplay.leases.isEmpty {
            autoLease = try virtualDisplay.acquire(
                reason: "auto: park --app \(request.app ?? "pid \(pid)")",
                kind: .auto,
            )
        }
        guard let bounds = virtualDisplay.virtualScreenBounds else {
            return [
                "ok": false,
                "error": "no virtual screen is attached and none could be brought up — isolation is unavailable",
            ]
        }
        // Inset from the corner so the title bar is reachable even if the display's
        // menu bar overlaps its top edge.
        let destination = CGPoint(x: bounds.origin.x + 40, y: bounds.origin.y + 40)

        isDriving = true
        defer { isDriving = false }
        let move = try await engine.moveWindow(pid: pid, windowTitle: request.window, to: destination)
        var reply = parkReply(for: move)
        if move.landed {
            virtualDisplay.recordPark(
                pid: pid,
                title: move.window,
                before: move.before.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
            )
        } else if let autoLease {
            // The lease existed only for this park; nothing landed on the display, so
            // holding it would leave a screen up for no window.
            _ = await virtualDisplay.release(autoLease)
        }
        if let autoLease, move.landed {
            reply["lease"] = autoLease.id.uuidString
            reply["leaseKind"] = "auto"
            reply["summary"] = "\(reply["summary"] ?? "") · auto-lease \(autoLease.id.uuidString.prefix(8))… taken (\(autoLease.reason))"
        }
        return reply
    }

    private func parkReply(for move: Engine.WindowMove) -> [String: Any] {
        var reply: [String: Any] = [
            "ok": move.landed,
            "window": move.window,
            "requested": ["x": move.requestedX, "y": move.requestedY],
            "summary": move.landed
                ? "moved '\(move.window)' to (\(Int(move.requestedX)), \(Int(move.requestedY)))"
                : (move.moved
                    ? "window moved but not to the requested point — the window manager clamped it"
                    : "window did not move"),
            "presence": presenceBlock(),
        ]
        if let before = move.before { reply["before"] = block(for: before) }
        if let after = move.after { reply["after"] = block(for: after) }
        return reply
    }

    /// Lists an app's menu bar status items, or presses one. Status items live in a separate
    /// extras menu bar no window walk reaches, so this is the only ghost path to a
    /// MenuBarExtra popover or status menu (measured gap, trial log 2026-08-22).
    private func statusItem(_ request: Request) async throws -> [String: Any] {
        let pid = try resolve(request)
        guard request.press == true else {
            let items = try await engine.statusItems(pid: pid)
            return [
                "ok": true,
                "items": items.map(elementRow),
                "count": items.count,
                "summary": items.isEmpty
                    ? "no status items — this app installs none"
                    : "\(items.count) status item(s); pass press:true to open one",
                "presence": presenceBlock(),
            ]
        }

        isDriving = true
        defer { isDriving = false }
        let result = try await engine.pressStatusItem(pid: pid, label: request.label)
        var reply = evidenceReply(result.evidence)
        reply["item"] = result.item
        return reply
    }

    // MARK: - Screenshots

    /// The default vision backend made concrete: capture pixels and hand them to the caller,
    /// whose own model does the looking. Captures the app's primary window when `--app` is
    /// given, an explicit region when x/y/w/h are, and the main display otherwise.
    ///
    /// With `since`, the reply becomes the pixel delta against that earlier capture of the
    /// same target: changed-region crops (or a scroll report) instead of the whole frame.
    private func screenshot(_ request: Request) async throws -> [String: Any] {
        guard ScreenCapture.isPermitted else {
            return [
                "ok": false,
                "error": "Screen Recording is not granted — run 'request-capture', or approve Rocuronium in System Settings",
            ]
        }
        // A diff reply writes zero, one, or several crops with derived names; an explicit
        // single path cannot describe that, and honoring it for only some outcomes would
        // make the file layout depend on what happened to change.
        if request.since != nil, request.path != nil {
            return [
                "ok": false,
                "error": "'--since' writes its region crops to the captures folder; '--path' applies to full captures only — drop one of the two",
            ]
        }

        // Resolve the destination before doing any work. Capturing first and then rejecting
        // the path spends a full-screen grab to deliver an error the caller could have had
        // immediately — and briefly holds screen contents in memory for a request that was
        // never going to be honored.
        let destination = try request.path.map(resolveCapturePath)

        // A process-scoped capture goes through the window filter, not a region of the display:
        // a region returns whatever is *topmost* there, and an occluded window would be captured
        // as someone else's pixels at exactly the right size — a correct-looking wrong answer.
        // Any of `app`, `pid`, or `window` names a target: a bare `--pid` (or `--window`) must
        // scope the same way `--app` does, never fall through to a full-display grab. A
        // `--window` with no process resolves through `resolve`, which asks for `--app`/`--pid`.
        if request.app != nil || request.pid != nil || request.window != nil {
            let pid = try resolve(request)
            // A named window that cannot be resolved refuses here rather than widening to the
            // primary window or the whole display — the measured hazard was a screenshot
            // silently capturing a bystander's windows.
            let frame = try await engine.windowFrame(pid: pid, title: request.window)
            let capture = try await ScreenCapture.windowImage(
                ownedBy: pid,
                near: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
            )
            let scale = capture.windowFrame.width > 0
                ? Double(capture.image.width) / Double(capture.windowFrame.width)
                : 2
            return try await captureReply(
                image: capture.image,
                key: "app:\(pid)",
                rect: capture.windowFrame,
                scale: scale,
                since: request.since,
                destination: destination,
                described: "window '\(capture.windowTitle)'",
                extra: ["window": capture.windowTitle],
            )
        }

        // The `--app` path inherits this guard through `engine.windowFrame`; the region and
        // full-display paths had none, so a capture with the display asleep returned
        // `ok: true` and a frame of black — a correct-looking picture of nothing, in exactly
        // the unattended-overnight case this tool is for.
        guard DisplayWake.perceptionIsReliable else {
            return [
                "ok": false,
                "error": "the display is asleep — a capture right now would be a black frame, not a picture of anything",
            ]
        }
        let explicitRegion = request.x != nil && request.y != nil && request.w != nil && request.h != nil
        let rect: CGRect = if explicitRegion {
            CGRect(x: request.x!, y: request.y!, width: request.w!, height: request.h!)
        } else {
            CGDisplayBounds(CGMainDisplayID())
        }
        guard let image = try await ScreenCapture.image(of: rect) else {
            return ["ok": false, "error": "the capture region is degenerate (\(rect))"]
        }
        let key = explicitRegion
            ? "rect:\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))"
            : "display:main"
        return try await captureReply(
            image: image,
            key: key,
            rect: rect,
            scale: rect.width > 0 ? Double(image.width) / Double(rect.width) : 2,
            since: request.since,
            destination: destination,
            described: explicitRegion ? "region" : "the main display",
            extra: [:],
        )
    }

    /// The shared back half of every screenshot: store the frame for future diffs, hand out
    /// its token, and — when `since` named a comparable frame — reply with the delta
    /// instead of the whole capture. Degrades are named in `diffNote`, never silent.
    private func captureReply(
        image: CGImage,
        key: String,
        rect: CGRect,
        scale: Double,
        since: String?,
        destination: URL?,
        described: String,
        extra: [String: Any]
    ) async throws -> [String: Any] {
        // The pre-diff reply shape, word for word: only the token (and any diff fields)
        // may be new.
        func fullSummary(_ url: URL) -> String {
            extra["window"] != nil
                ? "captured \(described) (\(image.width)x\(image.height) px) to \(url.path)"
                : "captured \(image.width)x\(image.height) px to \(url.path)"
        }
        var diffNote: String?
        var delta: [String: Any]?
        // Normalized once, up front: the diff needs byte-comparable layouts, and storing
        // the normalized form means the stored side of the *next* diff needs no re-decode.
        guard let bytes = await normalizedBytes(of: image) else {
            // No normalization means no diffing and no stored frame — say so instead of
            // handing out a token that could never be honored.
            let url = try await writePNG(image, to: destination)
            return [
                "ok": true,
                "path": url.path,
                "width": image.width,
                "height": image.height,
                "rect": block(for: rect),
                "diffNote": "the capture could not be fingerprinted, so no observation token was issued",
                "summary": fullSummary(url),
                "presence": presenceBlock(),
            ].merging(extra) { current, _ in current }
        }

        if let since {
            let echo = String(since.prefix(24))
            if let previous = frames.frame(for: since) {
                if previous.key != key {
                    diffNote = "token '\(echo)' covers a different capture target — returning the full capture"
                } else if previous.pixelWidth != image.width || previous.pixelHeight != image.height {
                    diffNote = "the captured size changed (\(previous.pixelWidth)x\(previous.pixelHeight) → "
                        + "\(image.width)x\(image.height) px) — the window was resized or moved between captures; returning the full capture"
                } else if let analysis = await analyzeFrames(
                    before: previous.bytes, after: bytes, width: image.width, height: image.height,
                ) {
                    (delta, diffNote) = try await self.deltaReply(
                        analysis, image: image, rect: rect, scale: scale, since: since, described: described,
                    )
                } else {
                    diffNote = "the two captures could not be compared — returning the full capture"
                }
            } else {
                diffNote = "unknown or evicted token '\(echo)' — returning the full capture"
            }
        }

        let token = frames.store(
            key: key, bytes: bytes,
            pixelWidth: image.width, pixelHeight: image.height,
        )

        if var delta {
            delta["token"] = token
            delta["since"] = since
            delta["rect"] = block(for: rect)
            delta["presence"] = presenceBlock()
            return delta.merging(extra) { current, _ in current }
        }

        let url = try await writePNG(image, to: destination)
        var reply: [String: Any] = [
            "ok": true,
            "path": url.path,
            "width": image.width,
            "height": image.height,
            "rect": block(for: rect),
            "token": token,
            "summary": fullSummary(url),
            "presence": presenceBlock(),
        ]
        if let diffNote { reply["diffNote"] = diffNote }
        return reply.merging(extra) { current, _ in current }
    }

    /// Turns a diff analysis into a reply, writing region crops as it goes. Returns the
    /// reply, or a degrade note when the honest answer is the full frame after all.
    private func deltaReply(
        _ analysis: FrameDiff.Analysis,
        image: CGImage,
        rect: CGRect,
        scale: Double,
        since: String,
        described: String
    ) async throws -> ([String: Any]?, String?) {
        /// A pixel-space region of the capture, as global screen points.
        func screenBlock(_ region: FrameDiff.Region) -> [String: Any] {
            [
                "x": rect.origin.x + Double(region.x) / scale,
                "y": rect.origin.y + Double(region.y) / scale,
                "w": Double(region.width) / scale,
                "h": Double(region.height) / scale,
            ]
        }
        func crop(_ region: FrameDiff.Region) async throws -> URL {
            guard let cropped = image.cropping(to: CGRect(
                x: region.x, y: region.y, width: region.width, height: region.height,
            )) else { throw RouterError.captureWriteFailed("crop \(region)") }
            return try await writePNG(cropped, to: nil)
        }

        switch analysis {
        case .unchanged:
            return ([
                "ok": true,
                "changed": false,
                "regionCount": 0,
                "regions": [[String: Any]](),
                "summary": "no visible change in \(described) since \(since)",
            ], nil)

        case let .scrolled(dy, revealed):
            let points = Int((Double(abs(dy)) / scale).rounded())
            let edge = dy > 0 ? "bottom" : "top"
            let url = try await crop(revealed)
            return ([
                "ok": true,
                "changed": true,
                "scrolledBy": points,
                "scrolledPx": dy,
                "revealed": screenBlock(revealed),
                "path": url.path,
                "summary": "content scrolled ~\(points) pt (\(abs(dy)) px, new content at the \(edge)) — edge strip at \(url.path)",
            ], nil)

        case let .regions(regions, changedFraction):
            var rows: [[String: Any]] = []
            for region in regions {
                let url = try await crop(region)
                rows.append(["rect": screenBlock(region), "path": url.path])
            }
            return ([
                "ok": true,
                "changed": true,
                "regionCount": rows.count,
                "regions": rows,
                "changedFraction": (changedFraction * 10_000).rounded() / 10_000,
                "summary": "\(rows.count) changed region(s) in \(described) since \(since) — crops written",
            ], nil)

        case let .wholesale(changedFraction):
            return (nil, "\(Int(changedFraction * 100))% of the frame changed — a diff would not be smaller than the truth; returning the full capture")
        }
    }

    /// Off the main actor for the same reason `writePNG` is: normalizing or diffing a
    /// full-display frame is tens of milliseconds of pixel work, and the menu bar (and its
    /// `isDriving` honesty) must not freeze for it.
    @concurrent private func normalizedBytes(of image: CGImage) async -> [UInt8]? {
        ScreenDiff.normalizedBytes(of: image)
    }

    @concurrent private func analyzeFrames(
        before: [UInt8], after: [UInt8], width: Int, height: Int
    ) async -> FrameDiff.Analysis? {
        FrameDiff.analyze(before: before, after: after, width: width, height: height)
    }

    /// Where a caller-supplied capture path may land, and why there is a rail at all.
    ///
    /// `CGImageDestinationCreateWithURL` truncates whatever is already there, so an unchecked
    /// path is an arbitrary-file overwrite: `--path ~/.zshrc` replaces it with PNG bytes. Over
    /// MCP the path is written by a *model*, so a hallucinated or mis-joined path is the
    /// likely trigger rather than an attacker. This is the same rail `type` already has, where
    /// an absent `text` is refused because defaulting to `""` would be an unrecoverable write.
    private func resolveCapturePath(_ explicitPath: String) throws -> URL {
        let url = URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
            .standardizedFileURL
        guard url.pathExtension.lowercased() == "png" else {
            throw RouterError.captureNotPNG(url.lastPathComponent)
        }
        // Refuse to clobber. There is no undo for a truncated file, and the caller who meant
        // to overwrite can delete first — an explicit act on their side, not a silent one here.
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw RouterError.captureExists(url.path)
        }
        let permitted = [
            URL.homeDirectory.appending(path: "Desktop"),
            URL.homeDirectory.appending(path: "Downloads"),
            URL.homeDirectory.appending(path: "Pictures"),
            URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL,
            URL(fileURLWithPath: "/tmp"),
            defaultCaptureDirectory,
        ]
        let directory = url.deletingLastPathComponent().standardizedFileURL
        guard permitted.contains(where: { directory.path.hasPrefix($0.standardizedFileURL.path) }) else {
            throw RouterError.captureOutsidePermittedDirectory(directory.path)
        }
        return url
    }

    private nonisolated var defaultCaptureDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "glass.kagerou.rocuronium")
            .appending(path: "captures")
    }

    /// Takes an already-resolved destination: validation happens before any capture, so a
    /// refused path costs nothing and never puts screen contents in memory.
    ///
    /// `@concurrent`, because a full-display PNG encode measures 0.5–2 s and this type is
    /// `@MainActor`: encoding inline froze the menu bar — including the `isDriving`
    /// indicator, the one signal that must stay honest while the engine works. Plain
    /// `nonisolated` would not move it: under NonisolatedNonsendingByDefault a nonisolated
    /// async function runs on the *caller's* executor.
    @concurrent private func writePNG(_ image: CGImage, to destination: URL?) async throws -> URL {
        let url: URL
        if let destination {
            url = destination
        } else {
            let directory = defaultCaptureDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sweepOldCaptures(in: directory)
            url = directory.appending(path: "capture-\(UUID().uuidString).png")
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil,
        ) else { throw RouterError.captureWriteFailed(url.path) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RouterError.captureWriteFailed(url.path)
        }
        return url
    }

    // MARK: - Resolution

    /// Name to pid, refusing ambiguity. Two same-named apps genuinely happen — a debug and a
    /// release build of the same product ran side by side (measured 2026-08-09), and `first`
    /// silently drove whichever the workspace listed first. A verb aimed at "the app named X"
    /// when two exist is a coin flip on somebody's real windows, so it is refused with the
    /// candidates listed; bundle ids are the disambiguator, and they are matched exactly.
    private func resolve(_ request: Request) throws -> pid_t {
        // An explicit pid is the address, not a hint: it wins over `app` outright, because
        // it exists for exactly the case name resolution cannot answer (two instances of
        // one bundle id). Refused when nothing runs there — acting on a recycled pid would
        // drive an app nobody chose.
        if let pid = request.pid {
            guard NSRunningApplication(processIdentifier: pid) != nil else {
                throw RouterError.appNotRunning("pid \(pid)")
            }
            return pid
        }
        guard let name = request.app else { throw RouterError.missingApp }
        let applications = NSWorkspace.shared.runningApplications

        let exactBundle = applications.filter { ($0.bundleIdentifier ?? "").lowercased() == name.lowercased() }
        let exactName = applications.filter { $0.localizedName == name }
        let looseName = applications.filter { $0.localizedName?.lowercased() == name.lowercased() }
        let matches = exactBundle.isEmpty ? (exactName.isEmpty ? looseName : exactName) : exactBundle
        guard let match = matches.first else { throw RouterError.appNotRunning(name) }
        guard matches.count == 1 else {
            throw RouterError.ambiguousApp(name, matches.map(Self.instanceDescription))
        }
        return match.processIdentifier
    }

    /// One running instance, spelled out enough to pick the right one: pid, bundle id, when
    /// it launched, and where it lives on disk. Picking the wrong pid from a bare list killed
    /// a live app once (trial log 2026-08-31); the start time and path are what disambiguate
    /// two instances of the same bundle.
    private static func instanceDescription(_ app: NSRunningApplication) -> String {
        var parts = ["'\(app.localizedName ?? "?")' (bundle \(app.bundleIdentifier ?? "?"), pid \(app.processIdentifier)"]
        if let started = app.launchDate {
            parts[0] += ", started \(ISO8601DateFormatter().string(from: started))"
        }
        parts[0] += ")"
        if let path = app.bundleURL?.path { parts.append("at \(path)") }
        return parts.joined(separator: " ")
    }


    /// Screenshots are screen contents — the most sensitive thing this app produces — and
    /// they were accumulating with no expiry. Same reasoning as the virtual display's lease
    /// TTL: state that nobody is holding should not outlive its usefulness. Best-effort and
    /// deliberately silent; a capture must not fail because cleanup did.
    private nonisolated func sweepOldCaptures(in directory: URL) {
        let cutoff = Date(timeIntervalSinceNow: -Constants.captureRetention)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
        ) else { return }
        for entry in entries where entry.pathExtension.lowercased() == "png" {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private nonisolated enum Constants {
        /// Long enough for an agent to read a capture it just took and for a human to find it
        /// afterwards; short enough that a day of automation does not leave a screen archive.
        static let captureRetention: TimeInterval = 24 * 60 * 60
        /// The socket cancels requests at 30 s; staying 5 under means a timed-out wait is
        /// reported as such, with "call again", instead of racing the cancellation and losing.
        static let maximumWaitSeconds = 25.0
        static let defaultWaitSeconds = 10.0
        /// A cold launch can legitimately take this long on a big Electron app.
        static let launchReadySeconds = 20.0
        /// Each OCR-scroll step costs ~0.5 s (capture + fast OCR + settle); 12 stays well
        /// inside the socket's 30 s, and the reply says callAgain when more document remains.
        static let maximumScrollSearchSteps = 12
        /// An already-running app should answer almost immediately.
        static let relaunchReadySeconds = 5.0
    }

    private func block(for rect: CGRect) -> [String: Any] {
        ["x": rect.origin.x, "y": rect.origin.y, "w": rect.width, "h": rect.height]
    }

    private func block(for frame: Engine.ElementDescriptor.Frame) -> [String: Any] {
        ["x": frame.x, "y": frame.y, "w": frame.width, "h": frame.height]
    }

    private func presenceBlock() -> [String: Any] {
        let presence = UserPresence.read()
        return [
            "state": presence.state.rawValue,
            "mayTakeCursor": presence.mayTakeCursor,
            "canSee": presence.canSee,
            "offConsole": presence.offConsole,
            "advice": presence.advice,
        ]
    }

    private func encode(_ payload: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(#"{"ok":false}"#.utf8)
    }

    enum RouterError: LocalizedError {
        case missingApp
        case appNotRunning(String)
        case ambiguous(String, [String])
        case ambiguousApp(String, [String])
        case captureWriteFailed(String)
        case captureNotPNG(String)
        case captureExists(String)
        case captureOutsidePermittedDirectory(String)

        var errorDescription: String? {
            switch self {
            case .missingApp: "No 'app' given."
            case let .appNotRunning(name): "'\(name)' is not running."
            case let .ambiguous(query, candidates):
                "'\(query)' matched \(candidates.count) elements: \(candidates.joined(separator: ", ")). Be more specific."
            case let .ambiguousApp(name, candidates):
                "\(candidates.count) running apps are named '\(name)': \(candidates.joined(separator: "; ")). "
                    + "Target one by its bundle id — acting on whichever listed first would drive the wrong app."
            case let .captureWriteFailed(path): "Could not write the capture to \(path)."
            case let .captureNotPNG(name):
                "'\(name)' is not a .png path — captures are PNG, and writing one over a file of another type would destroy it."
            case let .captureExists(path):
                "\(path) already exists. Captures never overwrite; delete it first or choose another name."
            case let .captureOutsidePermittedDirectory(path):
                "\(path) is outside the directories captures may be written to (Desktop, Downloads, Pictures, /tmp, or the app's own captures folder)."
            }
        }
    }
}
