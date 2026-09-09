import Foundation
import Security

/// The one signing identity the daemon trusts: Apple-anchored, this team, and a named binary.
///
/// Two callers, two directions. The control socket asks about a *running* peer, identified by
/// audit token so a recycled pid cannot stand in for the process that connected. The Adrafinil
/// bridge asks about a *file* it is about to execute — a child spawned by this app inherits its
/// TCC responsibility, so whatever is at that path would run with the Accessibility and Screen
/// Recording grants; it is checked before every spawn, and an unsigned or foreign binary at the
/// expected path is treated as absent.
nonisolated enum CodeIdentity {
    static let teamIdentifier = "52K336H235"

    /// The standard Developer ID form, narrowed to named identifiers. Team alone would admit
    /// every binary the team signs; the identifier clause keeps each trust decision to the
    /// binaries it was made for.
    static func requirement(identifiers: [String]) -> String {
        let named = identifiers.map { #"identifier "\#($0)""# }.joined(separator: " or ")
        return #"anchor apple generic and certificate leaf[subject.OU] = "\#(teamIdentifier)" and (\#(named))"#
    }

    /// Whether the running code behind an audit token (or, failing that, a pid) satisfies the
    /// requirement. The audit token is the race-free identity; the pid is a fallback for a
    /// socket that could not supply one.
    static func isTrusted(auditToken: Data?, pid: pid_t, identifiers: [String]) -> Bool {
        var attributes: [String: Any] = [:]
        if let auditToken {
            attributes[kSecGuestAttributeAudit as String] = auditToken
        } else if pid > 0 {
            attributes[kSecGuestAttributePid as String] = pid
        } else {
            return false
        }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
              let code, let requirement = makeRequirement(identifiers)
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Whether the executable at `path` satisfies the requirement, evaluated on the bytes on
    /// disk. There is no launch-time equivalent, so a window remains between this check and
    /// the exec; it is the width of a file replacement, and the replacement itself needs the
    /// team's signing key to pass.
    static func isTrusted(executableAt path: String, identifiers: [String]) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode, let requirement = makeRequirement(identifiers)
        else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }

    private static func makeRequirement(_ identifiers: [String]) -> SecRequirement? {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(
            requirement(identifiers: identifiers) as CFString, [], &compiled,
        ) == errSecSuccess else { return nil }
        return compiled
    }
}
