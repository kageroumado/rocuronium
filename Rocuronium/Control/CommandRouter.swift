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
final class CommandRouter {
    private let cache = TreeCache()
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
        case "type": try await act(request, action: .setText(request.text ?? ""))
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
        ]
        do {
            let image = try await ScreenCapture.image(of: CGRect(x: 0, y: 0, width: 16, height: 16))
            report["captureAttempt"] = image == nil ? "returned nil" : "succeeded (\(image!.width)x\(image!.height) px)"
        } catch {
            report["captureAttempt"] = "threw: \(error)"
        }
        return report
    }

    private func find(_ request: Request) async throws -> [String: Any] {
        let pid = try resolve(request)
        let query = request.label
        let key = "find:\(query ?? "*")"
        let results = await cache.results(for: pid, key: key) {
            if let query { ElementQuery.named(query, pid: pid) } else { ElementQuery.editables(pid: pid) }
        }
        let matches = results.matches.prefix(20).map { match in
            [
                "role": match.element.role,
                "label": match.element.label,
                "value": match.element.value ?? "",
                "depth": match.depth,
                "frame": match.element.frame.map {
                    ["x": $0.origin.x, "y": $0.origin.y, "w": $0.width, "h": $0.height]
                } ?? [:],
            ] as [String: Any]
        }
        return [
            "ok": true,
            "matches": matches,
            "truncated": results.truncated,
            "elementsVisited": results.elementsVisited,
            "presence": presenceBlock(),
        ]
    }

    private func act(_ request: Request, action: GhostLadder.Action) async throws -> [String: Any] {
        let pid = try resolve(request)
        guard let element = try locate(request, pid: pid) else {
            return ["ok": false, "error": "no element matched", "presence": presenceBlock()]
        }
        let ladder = GhostLadder(allowHardwareInput: request.allowHardwareInput ?? false)
        let evidence = await ladder.perform(action, on: element, pid: pid)
        // The interface just changed; anything cached about this process is now suspect.
        await cache.invalidate(pid: pid)
        return [
            "ok": evidence.succeeded,
            "verdict": evidence.verdict.rawValue,
            "rung": evidence.rung.rawValue,
            "summary": evidence.summary,
            "readback": evidence.readback ?? "",
            "cursorMoved": evidence.cursorMoved,
            "frontmostChanged": evidence.frontmostChanged,
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

    /// A coordinate resolves by hit-test; a label resolves by search; neither falls back to
    /// the other, so a caller always knows which one answered.
    private func locate(_ request: Request, pid: pid_t) throws -> AXElement? {
        if let x = request.x, let y = request.y {
            return ElementQuery.hitTest(CGPoint(x: x, y: y), pid: pid)
        }
        guard let label = request.label else { return ElementQuery.focused(pid: pid) }
        return ElementQuery.named(label, pid: pid).matches.first?.element
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

        var errorDescription: String? {
            switch self {
            case .missingApp: "No 'app' given."
            case let .appNotRunning(name): "'\(name)' is not running."
            }
        }
    }
}
