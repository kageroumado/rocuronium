import Darwin
import Foundation

/// BSD process metadata readable across user accounts by the console daemon.
nonisolated enum SessionProcessTable {
    struct Entry: Equatable {
        let pid: pid_t
        let name: String
        let started: Date
    }

    static func entries(ownedBy uid: uid_t) throws -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
        // Processes may start between sizing and reading. Retry a growing table.
        for _ in 0 ..< 3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
            size = entries.count * MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, UInt32(mib.count), &entries, &size, nil, 0) == 0 else {
                if errno == ENOMEM { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return entries.prefix(size / MemoryLayout<kinfo_proc>.stride).map { entry in
                var process = entry.kp_proc
                let name = withUnsafeBytes(of: &process.p_comm) {
                    String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                let start = process.p_un.__p_starttime
                return Entry(pid: process.p_pid, name: name,
                             started: Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000))
            }
        }
        throw POSIXError(.ENOMEM)
    }

    static func loginWindow(of uid: uid_t) throws -> Entry? {
        try entries(ownedBy: uid).first { $0.name == "loginwindow" }
    }
}
