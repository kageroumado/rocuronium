import AppKit
import ApplicationServices
import Foundation
import ImageIO
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

    /// All accessibility work happens here, off the main actor. See `Engine`.
    private let engine = Engine()
    private let virtualDisplay = VirtualDisplayBridge()

    struct Request: Decodable {
        let command: String
        var app: String?
        var label: String?
        var text: String?
        var x: Double?
        var y: Double?
        /// Opt-in to the cursor-stealing rung. Absent means no.
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
    }

    func route(_ data: Data) async -> Data {
        do {
            let request = try JSONDecoder().decode(Request.self, from: data)
            return encode(try await execute(request))
        } catch {
            // Interpolating a Swift error enum prints its case name ("notInstalled"), which
            // tells the caller nothing; the description written for humans is the reply.
            let description = (error as? any LocalizedError)?.errorDescription ?? "\(error)"
            return encode(["ok": false, "error": description])
        }
    }

    // MARK: - Commands

    private func execute(_ request: Request) async throws -> [String: Any] {
        switch request.command {
        case "status": status()
        case "diag": await diagnose()
        case "request-capture": requestCapture()
        case "find": try await find(request)
        case "type": try await typeCommand(request)
        case "click": try await act(request, action: .click)
        case "display": try await display(request)
        case "park": try await park(request)
        case "screenshot": try await screenshot(request)
        default: ["ok": false, "error": "unknown command '\(request.command)'"]
        }
    }

    private func status() -> [String: Any] {
        let presence = UserPresence.read()
        return [
            "ok": true,
            "trusted": AXIsProcessTrusted(),
            "presence": presence.state.rawValue,
            "idleSeconds": Int(presence.idleSeconds),
            "screenLocked": presence.screenLocked,
            "displayAsleep": presence.displayAsleep,
            "canSee": presence.canSee,
            "mayTakeCursor": presence.mayTakeCursor,
            "advice": presence.advice,
            "virtualDisplayActive": virtualDisplay.activeLease != nil,
        ]
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

    private func find(_ request: Request) async throws -> [String: Any] {
        let pid = try resolve(request)
        let outcome = try await engine.find(pid: pid, query: request.label)
        return [
            "ok": true,
            "matches": outcome.elements.map { element -> [String: Any] in
                var row: [String: Any] = [
                    "role": element.role,
                    "label": element.label,
                    "value": element.value,
                    "depth": element.depth,
                ]
                if let frame = element.frame {
                    row["frame"] = ["x": frame.x, "y": frame.y, "w": frame.width, "h": frame.height]
                }
                return row
            },
            "truncated": outcome.truncated,
            "elementsVisited": outcome.elementsVisited,
            "canSee": true,
            "cache": ["hits": outcome.cacheHits, "misses": outcome.cacheMisses],
            "presence": presenceBlock(),
        ]
    }

    private func act(_ request: Request, action: GhostLadder.Action) async throws -> [String: Any] {
        let pid = try resolve(request)
        // A coordinate is answered by a hit-test and a label by a search; neither falls back to
        // the other, so the caller always knows which mechanism replied.
        let locator: Engine.Locator = if let x = request.x, let y = request.y {
            .point(x: x, y: y)
        } else if let label = request.label {
            .named(label)
        } else {
            .focused
        }

        isDriving = true
        defer { isDriving = false }
        let evidence = try await engine.act(
            pid: pid, locator: locator, action: action,
            allowHardwareInput: request.allowHardwareInput ?? false,
        )

        return [
            "ok": evidence.succeeded,
            "verdict": evidence.verdict.rawValue,
            "rung": evidence.rung.rawValue,
            "summary": evidence.summary,
            "readback": evidence.readback ?? "",
            "cursorMoved": evidence.cursorMoved,
            "cursorMovedByUs": evidence.cursorMovedByUs,
            "cursorMovedByUser": evidence.cursorMovedByUser,
            "frontmostChanged": evidence.frontmostChanged,
            "focusTakenByUs": evidence.focusTakenByUs,
            "attempts": evidence.attempts.map { ["rung": $0.rung.rawValue, "outcome": $0.outcome] },
            "presence": presenceBlock(),
        ]
    }

    // MARK: - Virtual display

    /// Lease lifecycle over the socket. Leases are explicit on purpose: an agent that wants a
    /// display asks for one, gets an id, and gives it back — the display is never a silent
    /// side effect of some other command, because a stray virtual screen is confusing and
    /// whoever left it running should be findable in the lease's reason.
    private func display(_ request: Request) async throws -> [String: Any] {
        switch request.action {
        case "acquire":
            let lease: VirtualDisplayBridge.Lease
            if let minutes = request.minutes, minutes > 0 {
                lease = try await virtualDisplay.acquire(
                    reason: request.reason ?? "socket client",
                    duration: .seconds(minutes * 60),
                )
            } else {
                lease = try await virtualDisplay.acquire(reason: request.reason ?? "socket client")
            }
            var reply: [String: Any] = [
                "ok": true,
                "lease": lease.id.uuidString,
                "summary": "virtual display leased (\(lease.reason))",
            ]
            if let bounds = virtualDisplay.virtualScreenBounds { reply["screen"] = block(for: bounds) }
            return reply

        case "release":
            guard let id = request.lease.flatMap(UUID.init(uuidString:)) else {
                return ["ok": false, "error": "'display release' requires --lease <id> from acquire"]
            }
            guard virtualDisplay.release(id: id) else {
                return ["ok": false, "error": "no outstanding lease \(id.uuidString) — already released or expired"]
            }
            let holders = virtualDisplay.leases.count
            return [
                "ok": true,
                "leasesRemaining": holders,
                "summary": holders == 0
                    ? "released; no holders remain, display torn down (if it was ours)"
                    : "released; \(holders) other holder(s) keep the display up",
            ]

        case "status", nil:
            var reply: [String: Any] = [
                "ok": true,
                "installed": virtualDisplay.isInstalled,
                "running": virtualDisplay.isRunning,
                "leases": virtualDisplay.leases.values.map {
                    ["id": $0.id.uuidString, "reason": $0.reason] as [String: Any]
                },
                "summary": virtualDisplay.isRunning
                    ? "running · \(virtualDisplay.leases.count) lease(s)"
                    : (virtualDisplay.isInstalled ? "installed, not running" : "Test Display.app is not installed"),
            ]
            if let bounds = virtualDisplay.virtualScreenBounds { reply["screen"] = block(for: bounds) }
            return reply

        default:
            return ["ok": false, "error": "unknown display action '\(request.action ?? "")' — use acquire, release, or status"]
        }
    }

    /// Moves an app's primary window — onto the virtual display by default, or to an explicit
    /// point (which is also how a caller puts a window back where it found it: `park` replies
    /// carry the window's previous position).
    private func park(_ request: Request) async throws -> [String: Any] {
        let pid = try resolve(request)
        let destination: CGPoint
        if let x = request.x, let y = request.y {
            destination = CGPoint(x: x, y: y)
        } else if let bounds = virtualDisplay.virtualScreenBounds {
            // Inset from the corner so the title bar is reachable even if the display's
            // menu bar overlaps its top edge.
            destination = CGPoint(x: bounds.origin.x + 40, y: bounds.origin.y + 40)
        } else {
            return [
                "ok": false,
                "error": "no virtual display is attached — run 'display acquire' first, or pass --x/--y for an explicit destination",
            ]
        }

        isDriving = true
        defer { isDriving = false }
        let move = try await engine.moveWindow(pid: pid, to: destination)

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

    // MARK: - Screenshots

    /// The default vision backend made concrete: capture pixels and hand them to the caller,
    /// whose own model does the looking. Captures the app's primary window when `--app` is
    /// given, an explicit region when x/y/w/h are, and the main display otherwise.
    private func screenshot(_ request: Request) async throws -> [String: Any] {
        guard ScreenCapture.isPermitted else {
            return [
                "ok": false,
                "error": "Screen Recording is not granted — run 'request-capture', or approve Rocuronium in System Settings",
            ]
        }

        // An app capture goes through the window filter, not a region of the display: a region
        // returns whatever is *topmost* there, and an occluded window would be captured as
        // someone else's pixels at exactly the right size — a correct-looking wrong answer.
        if request.app != nil {
            let pid = try resolve(request)
            let frame = try await engine.windowFrame(pid: pid)
            let capture = try await ScreenCapture.windowImage(
                ownedBy: pid,
                near: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
            )
            let url = try writePNG(capture.image, to: request.path)
            return [
                "ok": true,
                "path": url.path,
                "width": capture.image.width,
                "height": capture.image.height,
                "window": capture.windowTitle,
                "rect": block(for: capture.windowFrame),
                "summary": "captured window '\(capture.windowTitle)' "
                    + "(\(capture.image.width)x\(capture.image.height) px) to \(url.path)",
                "presence": presenceBlock(),
            ]
        }

        let rect: CGRect = if let x = request.x, let y = request.y, let w = request.w, let h = request.h {
            CGRect(x: x, y: y, width: w, height: h)
        } else {
            CGDisplayBounds(CGMainDisplayID())
        }
        guard let image = try await ScreenCapture.image(of: rect) else {
            return ["ok": false, "error": "the capture region is degenerate (\(rect))"]
        }
        let url = try writePNG(image, to: request.path)
        return [
            "ok": true,
            "path": url.path,
            "width": image.width,
            "height": image.height,
            "rect": block(for: rect),
            "summary": "captured \(image.width)x\(image.height) px to \(url.path)",
            "presence": presenceBlock(),
        ]
    }

    private func writePNG(_ image: CGImage, to explicitPath: String?) throws -> URL {
        let url: URL
        if let explicitPath {
            url = URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
        } else {
            let directory = URL.applicationSupportDirectory
                .appending(path: "glass.kagerou.rocuronium")
                .appending(path: "captures")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    private func resolve(_ request: Request) throws -> pid_t {
        guard let name = request.app else { throw RouterError.missingApp }
        let applications = NSWorkspace.shared.runningApplications
        let match = applications.first { $0.localizedName == name }
            ?? applications.first { $0.localizedName?.lowercased() == name.lowercased() }
            ?? applications.first { ($0.bundleIdentifier ?? "").lowercased() == name.lowercased() }
        guard let match else { throw RouterError.appNotRunning(name) }
        return match.processIdentifier
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
        case captureWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingApp: "No 'app' given."
            case let .appNotRunning(name): "'\(name)' is not running."
            case let .ambiguous(query, candidates):
                "'\(query)' matched \(candidates.count) elements: \(candidates.joined(separator: ", ")). Be more specific."
            case let .captureWriteFailed(path): "Could not write the capture to \(path)."
            }
        }
    }
}
