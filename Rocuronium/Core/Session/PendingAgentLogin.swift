import Foundation

/// Written before requesting login so a relaunched daemon can finish abandoned cleanup.
struct PendingAgentLogin: Codable, Equatable {
    let account: String
    let uid: UInt32
    let observationDeadline: Date

    static var file: URL { AgentSessionLink.directory.appending(path: "pending-login.json") }

    static func load() throws -> Self? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Self?.self, from: Data(contentsOf: file))
    }

    static func save(_ pending: Self?) throws {
        let data = try JSONEncoder().encode(pending)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
