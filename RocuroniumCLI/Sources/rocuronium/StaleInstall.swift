import Darwin
import Foundation
import Security

/// Whether this process is running code that is no longer installed.
///
/// An MCP server lives as long as the agent session that spawned it — days, sometimes — while
/// `Scripts/install.sh` trashes the bundle it was started from. Such a process keeps running
/// the old binary, from the Trash or from a file that has since been deleted or replaced, and
/// stays on the old tool schemas until the client reconnects it. When a call fails, this
/// tells the agent that cause by name, so the fix (reconnect) is not left to guesswork.
nonisolated enum StaleInstall {
    /// The reconnect instruction for a stale server, or nil when this process is current.
    static func diagnosis() -> String? {
        diagnosis(executablePath: runningExecutablePath(), diskMatchesRunningCode: diskMatchesRunningCode())
    }

    static func diagnosis(executablePath: String?, diskMatchesRunningCode: Bool) -> String? {
        guard let executablePath, !executablePath.isEmpty else {
            return message(location: "a binary that has since been deleted")
        }
        if isInTrash(executablePath) || !diskMatchesRunningCode {
            return message(location: executablePath)
        }
        return nil
    }

    static func isInTrash(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    private static func message(location: String) -> String {
        "This rocuronium MCP server is running from an older install (\(location)). "
            + "Reconnect it (/mcp in Claude Code) to start the installed one."
    }

    /// The kernel's path for this process's executable, which follows the file through a move
    /// to the Trash — `CommandLine.arguments[0]` keeps the path it was launched by.
    private static func runningExecutablePath() -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// `errSecCSStaticCodeChanged` is Security's verdict that the file at this process's path
    /// is no longer the code it is running. Any other outcome is not evidence of staleness.
    private static func diskMatchesRunningCode() -> Bool {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return true }
        return SecCodeCheckValidity(me, [], nil) != errSecCSStaticCodeChanged
    }
}
