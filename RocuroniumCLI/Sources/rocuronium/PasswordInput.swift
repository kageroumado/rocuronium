import Darwin
import Foundation

enum PasswordInput {
    enum InputError: Error, Equatable, CustomStringConvertible {
        case unavailable
        case empty
        case tooLong
        case invalidEncoding

        var description: String {
            switch self {
            case .unavailable: "password entry was canceled or a secure terminal is unavailable"
            case .empty: "the password is empty"
            case .tooLong: "the password exceeds the interactive input limit"
            case .invalidEncoding: "the password must be UTF-8 text"
            }
        }
    }

    /// Interactive input hides typing and submits on Return. Pipes supply UTF-8 until EOF.
    static func read() throws -> String {
        guard isatty(STDIN_FILENO) == 1 else {
            return try decode(FileHandle.standardInput.readDataToEndOfFile())
        }
        let capacity = 4096
        var buffer = [CChar](repeating: 0, count: capacity)
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
        guard readpassphrase("Current password for the agent account: ", &buffer, capacity, RPP_REQUIRE_TTY) != nil else {
            throw InputError.unavailable
        }
        let length = buffer.firstIndex(of: 0) ?? capacity
        guard length < capacity - 1 else { throw InputError.tooLong }
        return try decode(Data(buffer.prefix(length).map { UInt8(bitPattern: $0) }))
    }

    static func decode(_ data: Data) throws -> String {
        guard var password = String(data: data, encoding: .utf8) else { throw InputError.invalidEncoding }
        if password.hasSuffix("\r\n") { password.removeLast() }
        else if password.hasSuffix("\n") { password.removeLast() }
        guard !password.isEmpty else { throw InputError.empty }
        return password
    }
}
