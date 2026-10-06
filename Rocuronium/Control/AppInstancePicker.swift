import AppKit
import CoreGraphics

/// Which of several running apps that answer to one `--app` a verb means.
///
/// A debug and a release build of the same product running side by side both answer to its
/// name (measured with Refrax, 2026-10-02: `--app Refrax` was refused and the caller stalled).
/// The pick follows what the human is looking at, in order:
///
/// 1. the instance that is frontmost;
/// 2. for a coordinate action, the only instance with an on-screen window at the aim point;
/// 3. the only instance with any on-screen window.
///
/// Anything else is refused with each candidate's pid and bundle path, and `--pid` is the
/// answer. The reply's `appResolution` says which rule chose, so the pick is never silent.
nonisolated enum AppInstancePicker {
    struct Candidate: Sendable, Equatable {
        let pid: pid_t
        let frontmost: Bool
        /// Frames of the instance's on-screen, normal-layer windows (top-left points).
        let windowFrames: [CGRect]
    }

    enum Pick: Equatable, Sendable {
        case chosen(pid: pid_t, reason: String)
        case ambiguous
    }

    static func pick(_ candidates: [Candidate], aim: CGPoint?) -> Pick {
        let frontmost = candidates.filter(\.frontmost)
        if frontmost.count == 1 {
            return .chosen(pid: frontmost[0].pid, reason: "frontmost")
        }
        if let aim {
            let atPoint = candidates.filter { $0.windowFrames.contains { $0.contains(aim) } }
            if atPoint.count == 1 {
                return .chosen(pid: atPoint[0].pid, reason: "the only one with a window at (\(Int(aim.x)), \(Int(aim.y)))")
            }
        }
        let withWindows = candidates.filter { !$0.windowFrames.isEmpty }
        if withWindows.count == 1 {
            return .chosen(pid: withWindows[0].pid, reason: "the only one with an on-screen window")
        }
        return .ambiguous
    }

    /// The live candidates for these apps: frontmost state and on-screen window frames.
    @MainActor
    static func candidates(for applications: [NSRunningApplication]) -> [Candidate] {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        return applications.map { application in
            let pid = application.processIdentifier
            let frames: [CGRect] = windows.compactMap { info in
                guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds),
                      rect.width >= 2, rect.height >= 2
                else { return nil }
                return rect
            }
            return Candidate(pid: pid, frontmost: application.isActive, windowFrames: frames)
        }
    }
}
