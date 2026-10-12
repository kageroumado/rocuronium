import Foundation
import ServiceManagement

/// The app's side of `rocuronium-session-helper`, the root LaunchDaemon that provisions agent
/// accounts.
///
/// Registered through `SMAppService`, which makes the authorization a one-time switch the human
/// turns on in System Settings → General → Login Items & Extensions, not a password typed per
/// run. The daemon's plist ships in `Contents/Library/LaunchDaemons`; the helper itself checks
/// that every message comes from this app's Developer ID signature.
nonisolated enum SessionHelperClient {
    static let plistName = "glass.kagerou.rocuronium.session-helper.plist"
    static let serviceName = "glass.kagerou.rocuronium.session-helper"

    static var service: SMAppService { SMAppService.daemon(plistName: plistName) }

    enum Availability: String {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
    }

    static var availability: Availability {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    /// Registers the daemon if needed. Returns what the human still has to do, or nil when the
    /// helper is ready. Asks once: an approval already pending opens Settings at the right pane
    /// instead of registering again.
    @MainActor
    static func ensureRegistered() -> String? {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(plistName)")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            return "the session helper configuration is missing at \(plist.path) — install a build that includes it"
        }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/rocuronium-session-helper")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return "the session helper executable is missing or cannot run at \(executable.path) — reinstall Rocuronium"
        }
        return registerIfNeeded(
            status: { availability },
            register: { try service.register() },
            openSettings: { SMAppService.openSystemSettingsLoginItems() },
        )
    }

    /// Resolves service registration and returns the human action required to finish it.
    @MainActor
    static func registerIfNeeded(
        status: () -> Availability,
        register: () throws -> Void,
        openSettings: () -> Void,
    ) -> String? {
        switch status() {
        case .enabled:
            return nil
        case .notFound, .notRegistered:
            // macOS can report notFound when the background-task registration record is absent.
            do {
                try register()
            } catch {
                if status() != .requiresApproval {
                    let error = error as NSError
                    return "registering the session helper failed: \(error.localizedDescription) (\(error.domain) \(error.code))"
                }
            }
            switch status() {
            case .enabled: return nil
            case .requiresApproval: break
            case .notFound, .notRegistered:
                return "the session helper registration is still unresolved (status: \(status().rawValue))"
            }
            fallthrough
        case .requiresApproval:
            openSettings()
            return "approve \"Rocuronium\" under Login Items & Extensions → Allow in the Background (System Settings is open there), then run enable again. "
                + "The helper runs as root only to create the agent account and add it to the Screen Sharing and Remote Login access lists."
        }
    }

    /// One request, one reply. Blocking; call off the main actor.
    static func send(_ fields: [String: String]) -> [String: Any] {
        let connection = xpc_connection_create_mach_service(serviceName, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        defer { xpc_connection_cancel(connection) }
        let message = xpc_dictionary_create(nil, nil, 0)
        for (key, value) in fields { xpc_dictionary_set_string(message, key, value) }
        let reply = xpc_connection_send_message_with_reply_sync(connection, message)
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
            return ["ok": false, "error": "the session helper did not answer (is it approved in Login Items & Extensions?)"]
        }
        var result: [String: Any] = ["ok": xpc_dictionary_get_bool(reply, "ok")]
        if let error = xpc_dictionary_get_string(reply, "error") { result["error"] = String(cString: error) }
        if xpc_dictionary_get_value(reply, "uid") != nil { result["uid"] = Int(xpc_dictionary_get_int64(reply, "uid")) }
        result["created"] = xpc_dictionary_get_bool(reply, "created")
        if let log = xpc_dictionary_get_array(reply, "log") {
            result["log"] = (0 ..< xpc_array_get_count(log)).compactMap { index in
                xpc_array_get_string(log, index).map { String(cString: $0) }
            }
        }
        return result
    }
}

extension AgentSessionController {
    /// `session enable`: the helper approval (once), this daemon's SSH key and the pinned host
    /// key, a password in the keychain, and the account provisioned behind them.
    ///
    /// A new account gets a generated password nobody types — the daemon reads it from the
    /// keychain when it opens a session. An existing account needs its current password, on
    /// stdin, since changing an existing account's password needs a SecureToken unlock that
    /// provisioning does not have.
    func enable(password suppliedPassword: String?, account requested: String?) async -> [String: Any] {
        let account = requested ?? account
        do {
            if let uid = Self.uid(of: account), let pid = try Self.loginWindow(of: uid) {
                return ["ok": false, "error": "'\(account)' has a running session (loginwindow pid \(pid)) — stop it first: rocuronium session stop"]
            }
        } catch {
            return ["ok": false, "error": "could not inspect the agent session: \(error)"]
        }
        if let pending = SessionHelperClient.ensureRegistered() {
            return ["ok": false, "error": pending, "helper": SessionHelperClient.availability.rawValue]
        }
        let exists = Self.uid(of: account) != nil
        let password: String
        if let suppliedPassword, !suppliedPassword.isEmpty {
            password = suppliedPassword
        } else if exists {
            if let stored = AgentSessionKeychain.password(account: account) {
                password = stored
            } else {
                return ["ok": false, "error": "'\(account)' already exists; pass its password on stdin: rocuronium session enable --password-stdin"]
            }
        } else {
            password = AgentSessionKeychain.generatePassword()
        }
        let publicKey: String
        do {
            publicKey = try AgentSessionLink.prepareKeys()
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
        let fields = [
            "op": "provision", "name": account, "fullName": "Agent", "password": password,
            "authorizedKey": publicKey, "appPath": Bundle.main.bundlePath,
        ]
        let reply = await Task.detached(priority: .userInitiated) { SessionHelperClient.send(fields) }.value
        guard reply["ok"] as? Bool == true else {
            return ["ok": false, "error": reply["error"] as? String ?? "provisioning failed", "lines": reply["log"] ?? []]
        }
        let stored = AgentSessionKeychain.store(password: password, account: account)
        guard stored == errSecSuccess else {
            return ["ok": false, "error": "provisioned, but storing the password in the keychain failed (OSStatus \(stored))", "lines": reply["log"] ?? []]
        }
        UserDefaults.standard.set(account, forKey: "agentSession.account")
        var lines = (reply["log"] as? [String] ?? []).map { "· \($0)" }
        lines.append("password stored in the login keychain (\(AgentSessionKeychain.service))")
        lines.append("")
        lines.append("One step is left, and it is yours: inside the agent session, grant Rocuronium Accessibility.")
        lines.append("Start the agent session with Screen Sharing and approve the")
        lines.append("Accessibility prompt there with an administrator's name and password. Until then the daemon")
        lines.append("inside can read but every posted event is silently dropped.")
        return ["ok": true, "account": account, "uid": reply["uid"] ?? 0, "created": reply["created"] ?? false, "lines": lines,
                "summary": "agent session enabled for \(account)"]
    }
}
