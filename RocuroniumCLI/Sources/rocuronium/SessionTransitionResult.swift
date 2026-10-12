import Foundation

enum SessionTransitionResult {
    /// A followed transition succeeds once the controller reaches its terminal state.
    static func failure(in reply: [String: Any], action: String) -> String? {
        if let error = reply["error"] as? String { return error }
        let target = action == "stop" ? "idle" : "running"
        if reply["state"] as? String == target, reply["ok"] as? Bool == true { return nil }
        if let error = reply["lastError"] as? String { return error }
        return "could not confirm agent-session \(action): expected \(target), received \(reply["state"] as? String ?? "unknown")"
    }
}
