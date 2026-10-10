import Foundation
import LightweightCodeRequirements
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

    /// The running-process form of ``requirement(identifiers:)``, evaluated by the kernel:
    /// a Developer ID signature that code signing accepted at exec, this team, a named binary,
    /// and a signature still valid now (`CS_VALID`, cleared when a page fails validation).
    static func processRequirement(
        team: String = teamIdentifier, identifiers: [String],
    ) throws -> ProcessCodeRequirement {
        try .allOf {
            ValidationCategory(.developerID)
            TeamIdentifier(team)
            SigningIdentifier.in(identifiers)
            ProcessCodeSigningFlags.isSuperset(of: [.isDynamicallyValid])
        }
    }

    /// Whether the process behind an audit token satisfies ``processRequirement(team:identifiers:)``.
    ///
    /// Judged on what the kernel recorded when the process was exec'd, NOT on the file at its
    /// path — `SecCodeCheckValidity` re-reads that file, so a long-lived client whose bundle was
    /// replaced or trashed by a reinstall fails it with `errSecCSStaticCodeChanged` while running
    /// exactly the code it was signed as. The audit token names the process race-free; a pid
    /// could be recycled between connect and check.
    static func isTrusted(auditToken: audit_token_t, team: String = teamIdentifier, identifiers: [String]) -> Bool {
        guard let task = SecTaskCreateWithAuditToken(nil, auditToken),
              let requirement = try? processRequirement(team: team, identifiers: identifiers)
        else { return false }
        // Throws `taskIsNoLongerValid` once the peer has exited; an absent peer is untrusted.
        return (try? SecTaskValidateForRequirement(task: task, requirement: requirement)) == true
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
