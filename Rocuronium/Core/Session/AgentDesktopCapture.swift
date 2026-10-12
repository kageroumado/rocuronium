import Foundation

/// Carries generated PNG captures across the account boundary and saves local reply paths.
nonisolated enum AgentDesktopCapture {
    static let maximumBytes = 16 * 1024 * 1024
    static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    struct Invalid: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func pack(_ reply: [String: Any], directory: URL) throws -> [String: Any] {
        var remaining = maximumBytes
        return try transform(reply) { object in
            var object = object
            guard let path = object["path"] as? String else { return object }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path,
                  url.pathExtension == "png" else { return object }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= remaining else { throw Invalid("agent captures exceed the 16 MiB transfer limit; capture a smaller region") }
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= remaining, bytes.starts(with: pngSignature) else { throw Invalid("invalid agent PNG capture") }
            remaining -= bytes.count
            object["_agentPNG"] = bytes.base64EncodedString()
            return object
        }
    }

    static func unpack(_ reply: [String: Any], directory: URL, destination: URL? = nil) throws -> [String: Any] {
        var remaining = maximumBytes
        var replacements: [String: String] = [:]
        let rootPath = reply["path"] as? String
        let imported = try transform(reply) { object in
            var object = object
            guard let encoded = object.removeValue(forKey: "_agentPNG") as? String else { return object }
            guard encoded.utf8.count <= (remaining + 2) / 3 * 4,
                  let bytes = Data(base64Encoded: encoded), bytes.count <= remaining,
                  bytes.starts(with: pngSignature), let oldPath = object["path"] as? String else {
                throw Invalid("invalid agent capture transfer")
            }
            remaining -= bytes.count
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = oldPath == rootPath ? destination ?? directory.appending(path: "agent-\(UUID().uuidString).png")
                : directory.appending(path: "agent-\(UUID().uuidString).png")
            try bytes.write(to: url, options: .withoutOverwriting)
            object["path"] = url.path
            replacements[oldPath] = url.path
            return object
        }
        return try transform(imported) { object in
            var object = object
            if var summary = object["summary"] as? String {
                for (old, new) in replacements { summary = summary.replacingOccurrences(of: old, with: new) }
                object["summary"] = summary
            }
            return object
        }
    }

    private static func transform(_ object: [String: Any], visit: ( [String: Any]) throws -> [String: Any]) throws -> [String: Any] {
        var object = object
        for (key, value) in object {
            if let nested = value as? [String: Any] { object[key] = try transform(nested, visit: visit) }
            else if let rows = value as? [[String: Any]] { object[key] = try rows.map { try transform($0, visit: visit) } }
        }
        return try visit(object)
    }
}
