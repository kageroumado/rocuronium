import Darwin
import Foundation
import Security
import SessionKit
@preconcurrency import XPC

// rocuronium-session-helper — the root half of `rocuronium session enable`.
//
// A LaunchDaemon the app registers with SMAppService; the human approves it once in System
// Settings → General → Login Items & Extensions. It listens on one Mach service, accepts only
// the Developer-ID-signed Rocuronium app, and does exactly three things: provision an agent
// account, remove one (bootout first, always), and bootout one's session when the SSH path is
// gone. It never runs a shell, never takes a path to execute, and exits when idle.

let serviceName = "glass.kagerou.rocuronium.session-helper"
let teamIdentifier = "52K336H235"
/// The app, and only the app: the CLI and MCP server reach the helper through the daemon.
let clientRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "\#(teamIdentifier)" and identifier "glass.kagerou.rocuronium""#
let idleExitSeconds = 120.0

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("rocuronium-session-helper: runs as root under launchd, from Rocuronium.app\n".utf8))
    exit(1)
}

/// One request at a time: provisioning and removal must never interleave.
let work = DispatchQueue(label: "glass.kagerou.rocuronium.session-helper")
nonisolated(unsafe) var idleExit: DispatchWorkItem?

/// Exits after a quiet spell; launchd starts the helper again on the next message.
@Sendable func scheduleIdleExit() {
    idleExit?.cancel()
    let item = DispatchWorkItem { exit(0) }
    idleExit = item
    work.asyncAfter(deadline: .now() + idleExitSeconds, execute: item)
}

@Sendable func string(_ message: xpc_object_t, _ key: String) -> String? {
    xpc_dictionary_get_string(message, key).map { String(cString: $0) }
}

/// A provisioned account's LaunchAgent and forced command point into this bundle, so the
/// bundle must carry the app's own signature before its path is written anywhere.
@Sendable func isOurBundle(_ path: String) -> Bool {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(clientRequirement as CFString, [], &requirement) == errSecSuccess, let requirement
    else { return false }
    return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
}

@Sendable func handle(_ message: xpc_object_t, reply: xpc_object_t, peerUID: uid_t) {
    func fail(_ error: String) {
        xpc_dictionary_set_bool(reply, "ok", false)
        xpc_dictionary_set_string(reply, "error", error)
    }
    func setLog(_ lines: [String]) {
        let array = xpc_array_create(nil, 0)
        for line in lines { xpc_array_set_string(array, XPC_ARRAY_APPEND, line) }
        xpc_dictionary_set_value(reply, "log", array)
    }
    let system = LiveAccountSystem()
    switch string(message, "op") {
    case "ping":
        xpc_dictionary_set_bool(reply, "ok", true)
    case "provision":
        guard let name = string(message, "name"), let password = string(message, "password"),
              let key = string(message, "authorizedKey"), let appPath = string(message, "appPath")
        else { return fail("provision needs name, password, authorizedKey and appPath") }
        guard isOurBundle(appPath) else { return fail("\(appPath) is not a Rocuronium.app signed by team \(teamIdentifier)") }
        let request = ProvisioningRequest(
            name: name, fullName: string(message, "fullName") ?? "Agent", password: password,
            authorizedKey: key, appPath: appPath,
        )
        switch Provisioner().run(request, protecting: peerUID) {
        case let .provisioned(uid, created, log):
            xpc_dictionary_set_bool(reply, "ok", true)
            xpc_dictionary_set_int64(reply, "uid", Int64(uid))
            xpc_dictionary_set_bool(reply, "created", created)
            setLog(log)
        case let .refused(reason, log):
            fail(reason)
            setLog(log)
        }
    case "remove":
        guard let name = string(message, "name") else { return fail("remove needs name") }
        switch AccountRemoval.run(name: name, system: system, protecting: peerUID) {
        case let .removed(uid):
            xpc_dictionary_set_bool(reply, "ok", true)
            xpc_dictionary_set_int64(reply, "uid", Int64(uid))
        case .absent:
            xpc_dictionary_set_bool(reply, "ok", true)
            xpc_dictionary_set_bool(reply, "absent", true)
        case let .refused(reason):
            fail(reason)
        }
    case "bootout":
        // The kill path for when SSH is not: the same bootout the watcher performs, from root.
        guard let name = string(message, "name"), let uid = system.uid(of: name) else {
            return fail("bootout needs an existing account name")
        }
        if case let .refused(reason) = Provisioning.gate(name: name, system: system, protecting: peerUID),
           !reason.contains("running session") {
            return fail(reason)
        }
        let result = system.bootout(uid: uid)
        xpc_dictionary_set_bool(reply, "ok", true)
        xpc_dictionary_set_int64(reply, "status", Int64(result.status))
        xpc_dictionary_set_int64(reply, "remaining", Int64(system.processes(of: uid).count))
    default:
        fail("unknown op")
    }
}

let listener = xpc_connection_create_mach_service(serviceName, work, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
xpc_connection_set_event_handler(listener) { peer in
    guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
    // Checked against the peer's audit token on every message: a process that is not the
    // signed app has its messages dropped and the connection invalidated.
    guard xpc_connection_set_peer_code_signing_requirement(peer, clientRequirement) == 0 else {
        xpc_connection_cancel(peer)
        return
    }
    xpc_connection_set_target_queue(peer, work)
    xpc_connection_set_event_handler(peer) { message in
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY, let reply = xpc_dictionary_create_reply(message) else { return }
        handle(message, reply: reply, peerUID: xpc_connection_get_euid(peer))
        xpc_connection_send_message(peer, reply)
        scheduleIdleExit()
    }
    xpc_connection_activate(peer)
}
xpc_connection_activate(listener)
work.async { scheduleIdleExit() }
dispatchMain()
