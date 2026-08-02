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
        /// A keyboard shortcut for `shortcut`, e.g. "cmd+a".
        var keys: String?
        /// Report which menu item a shortcut resolves to without pressing it.
        var resolveOnly: Bool?
        /// Press a shortcut that resolves to a session- or data-destroying menu item.
        var confirm: Bool?
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
        case "shortcut": try await shortcut(request)
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
        return evidenceReply(evidence)
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
        let result = try await engine.pressShortcut(pid: pid, keys: keys, mode: mode)

        guard let evidence = result.evidence else {
            // Resolve-only: what would be pressed, without pressing it.
            var reply: [String: Any] = [
                "ok": true,
                "menuItem": result.menuPath,
                "enabled": result.itemReportedEnabled,
                "summary": "'\(keys)' resolves to '\(result.menuPath)' (not pressed)",
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
        if !result.itemReportedEnabled, result.evidence != nil {
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

    private func evidenceReply(_ evidence: Evidence) -> [String: Any] {
        var reply: [String: Any] = [
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
        // The measurement behind a visual verdict. Exposing it is what makes a wrong
        // threshold discoverable from outside instead of reading as a mystery no-effect.
        if let pixelDelta = evidence.pixelDelta { reply["pixelDelta"] = pixelDelta }
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
            destination = point
        } else if let bounds = virtualDisplay.virtualScreenBounds {
            // Parking onto the virtual screen requires holding a lease, even when the screen
            // already exists. Without this, a window can be moved onto a display nobody is
            // keeping alive — and when it goes (our teardown, an expiry, or the user quitting
            // a display they started themselves) the window is stranded somewhere its owner
            // cannot see or reach. Found by doing exactly that to a real Finder window.
            guard !virtualDisplay.leases.isEmpty else {
                return [
                    "ok": false,
                    "error": "the virtual display is running but you hold no lease on it — run 'display acquire' first, "
                        + "so the display cannot disappear out from under the parked window. Pass --x/--y to move a window anyway.",
                ]
            }
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

        // Resolve the destination before doing any work. Capturing first and then rejecting
        // the path spends a full-screen grab to deliver an error the caller could have had
        // immediately — and briefly holds screen contents in memory for a request that was
        // never going to be honored.
        let destination = try request.path.map(resolveCapturePath)

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
            let url = try await writePNG(capture.image, to: destination)
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
        let rect: CGRect = if let x = request.x, let y = request.y, let w = request.w, let h = request.h {
            CGRect(x: x, y: y, width: w, height: h)
        } else {
            CGDisplayBounds(CGMainDisplayID())
        }
        guard let image = try await ScreenCapture.image(of: rect) else {
            return ["ok": false, "error": "the capture region is degenerate (\(rect))"]
        }
        let url = try await writePNG(image, to: destination)
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

    private func resolve(_ request: Request) throws -> pid_t {
        guard let name = request.app else { throw RouterError.missingApp }
        let applications = NSWorkspace.shared.runningApplications
        let match = applications.first { $0.localizedName == name }
            ?? applications.first { $0.localizedName?.lowercased() == name.lowercased() }
            ?? applications.first { ($0.bundleIdentifier ?? "").lowercased() == name.lowercased() }
        guard let match else { throw RouterError.appNotRunning(name) }
        return match.processIdentifier
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
        case captureNotPNG(String)
        case captureExists(String)
        case captureOutsidePermittedDirectory(String)

        var errorDescription: String? {
            switch self {
            case .missingApp: "No 'app' given."
            case let .appNotRunning(name): "'\(name)' is not running."
            case let .ambiguous(query, candidates):
                "'\(query)' matched \(candidates.count) elements: \(candidates.joined(separator: ", ")). Be more specific."
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
