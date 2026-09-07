import Foundation

/// A plan is a JSON step list, not a program: each step is an existing verb with an expected
/// postcondition and a failure policy. The daemon executes them in order, interpolating
/// between guards; the reply is one transcript.
struct SequencePlan: Decodable, Sendable {
    enum Profile: String, Decodable, Sendable {
        /// Tentacles 0–3, no overlay, no pacing.
        case ghost
        /// Bezel narration per step, jellyfish escort, human-paced.
        case visible
    }

    let profile: Profile
    let steps: [Step]

    struct Step: Decodable, Sendable {
        let command: String
        let app: String?
        let pid: pid_t?
        let label: String?
        let role: String?
        let x: Double?
        let y: Double?
        let text: String?
        let keys: String?
        let dx: Double?
        let dy: Double?
        let to: Double?
        let untilText: String?
        let action: String?
        let path: String?
        let w: Double?
        let h: Double?
        let since: String?
        let gone: Bool?
        let timeout: Double?
        let reason: String?
        let minutes: Double?
        let lease: String?
        let submit: Bool?
        let press: Bool?
        let start: String?
        let end: String?
        let via: String?
        let duration: Double?
        let easing: String?
        let button: String?
        let restore: Bool?
        let resolveOnly: Bool?
        let allowHardwareInput: Bool?
        let confirm: Bool?
        /// The real-activation click path, and the window-scoping trio — a plan step aimed at one
        /// of an app's several windows needs these as much as a top-level call does.
        let foreground: Bool?
        let window: String?
        let windowIndex: Double?
        let windowAt: String?
        /// Click shaping: modifier keys and click count.
        let modifiers: String?
        let count: Double?
        /// The move/drag dwell, and the perception opt-ins a step may carry.
        let dwell: Double?
        let observe: Bool?
        let ocr: Bool?
        let all: Bool?
        /// find paging.
        let limit: Double?
        let offset: Double?

        let expect: PlanGuard?
        let onFail: FailurePolicy?

        /// References into earlier steps' replies, resolved by the executor just before this
        /// step runs: `{"x": "$2.foundAt.cx", "y": "$2.foundAt.cy"}` sets this step's `x`/`y`
        /// from step 2's `foundAt` rectangle. A field here overrides the step's own value; the
        /// path is one level of reply keys, with `cx`/`cy` derived from a `{x,y,w,h}` block.
        /// Lives in its own map because the step's typed fields cannot hold a `$…` string.
        let refs: [String: String]?

        /// Encodes this step back into the flat dictionary the socket protocol expects.
        func asRequestJSON(profile: Profile) -> [String: Any] {
            var dict: [String: Any] = ["command": command]
            func set(_ key: String, _ value: Any?) { if let v = value { dict[key] = v } }
            set("app", app); set("pid", pid)
            set("label", label); set("role", role)
            set("x", x); set("y", y)
            set("text", text); set("keys", keys)
            set("dx", dx); set("dy", dy); set("to", to)
            set("untilText", untilText)
            set("action", action)
            set("path", path); set("w", w); set("h", h)
            set("since", since)
            set("gone", gone); set("timeout", timeout)
            set("reason", reason); set("minutes", minutes); set("lease", lease)
            set("submit", submit); set("press", press)
            set("start", start); set("end", end); set("via", via)
            set("duration", duration); set("easing", easing)
            set("button", button); set("restore", restore)
            set("resolveOnly", resolveOnly)
            set("confirm", confirm)
            set("foreground", foreground)
            set("window", window); set("windowIndex", windowIndex); set("windowAt", windowAt)
            set("modifiers", modifiers); set("count", count)
            set("dwell", dwell)
            set("observe", observe); set("ocr", ocr); set("all", all)
            set("limit", limit); set("offset", offset)
            if profile == .ghost, allowHardwareInput == nil {
                dict["allowHardwareInput"] = false
            } else {
                set("allowHardwareInput", allowHardwareInput)
            }
            return dict
        }

        var intent: String {
            var parts = [command]
            if let label { parts.append("'\(label)'") }
            if let app { parts.append("in \(app)") }
            if let text { parts.append("\"\(text.prefix(30))\(text.count > 30 ? "…" : "")\"") }
            if let keys { parts.append(keys) }
            return parts.joined(separator: " ")
        }
    }
}
