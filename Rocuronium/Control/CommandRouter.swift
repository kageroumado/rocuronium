import AppKit
import ApplicationServices
import Foundation

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
    }

    func route(_ data: Data) async -> Data {
        do {
            let request = try JSONDecoder().decode(Request.self, from: data)
            return encode(try await execute(request))
        } catch {
            return encode(["ok": false, "error": "\(error)"])
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

        var errorDescription: String? {
            switch self {
            case .missingApp: "No 'app' given."
            case let .appNotRunning(name): "'\(name)' is not running."
            case let .ambiguous(query, candidates):
                "'\(query)' matched \(candidates.count) elements: \(candidates.joined(separator: ", ")). Be more specific."
            }
        }
    }
}
