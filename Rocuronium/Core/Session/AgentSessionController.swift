import Darwin
import Foundation
import Security

/// How an off-console GUI session for the agent account comes into existence. Everything after
/// that — the dead-man's switch, the daemon inside, the bootout — is the controller's and is the
/// same whatever made the session.
@MainActor
protocol AgentSessionBringUp: AnyObject {
    /// A word for `status`: which route this is.
    var route: String { get }
    /// Whether the connection that keeps the session usable is still held. A session whose
    /// viewer went away is curtain-locked for good (measured 2026-08-28): `activate` and
    /// app-targeted keystrokes stop landing, and reattaching a viewer does not lift it.
    var isHeld: Bool { get }
    /// Asks the OS for the session and returns once the request is made; the controller then
    /// waits for the account's loginwindow to appear.
    func open(account: String, password: String, progress: @escaping @MainActor (String) -> Void) async throws
    func close()
}

/// The `session` verb's state: one agent account, at most one session for it, and never a
/// session without a dead-man's switch armed.
///
/// The lifecycle is **recreate on demand**. An idle session costs ~2.4 W even stripped — the
/// background daemons that cost it are platform binaries SIP will not let anyone stop — while a
/// fresh one costs a ~17 s start and a ~0.7 Wh burst, so past ~15 minutes idle, starting anew is
/// cheaper. Recreating also guarantees an unlocked session, which a long-lived one is not.
@MainActor
final class AgentSessionController {
    enum Phase: Equatable {
        case idle
        case starting
        case running(since: Date)
        case failed(String)
    }

    private enum Constants {
        static let accountKey = "agentSession.account"
        static let defaultAccount = "agent"
        /// From the request to the account's loginwindow existing; the measured spawn is ~10 s.
        static let sessionAppearTimeout: TimeInterval = 45
        /// From loginwindow to the daemon inside answering on its socket.
        static let daemonAnswerTimeout: TimeInterval = 40
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: [String] = []
    private var heartbeat: AgentSessionHeartbeat?
    /// A switch a start is still arming: a stop that lands meanwhile must close it too.
    private var heartbeatInFlight: AgentSessionHeartbeat?
    private var bringUp: (any AgentSessionBringUp)?
    private var startTask: Task<Void, Never>?
    /// Bumped by every start and every stop. A start compares its own number after each await,
    /// so one that was stopped or halted mid-flight can never arm a switch or report running
    /// after the stop has answered — cancelling the task alone would not stop it, since none of
    /// what it awaits checks for cancellation.
    private var generation = 0
    /// Builds the bring-up route for a start; nil when this Mac has none (see `AGENT-SESSION.md`).
    var makeBringUp: (@MainActor () -> (any AgentSessionBringUp)?)?
    /// Records start, stop, and the switch firing in the activity log.
    var record: (@MainActor (_ action: String, _ verdict: String, _ summary: String) -> Void)?

    var account: String {
        UserDefaults.standard.string(forKey: Constants.accountKey) ?? Constants.defaultAccount
    }

    var link: AgentSessionLink { AgentSessionLink(account: account) }

    init() {
        // Proof of life for the heartbeat thread: if the main actor stops reaching this, the
        // beats stop and the agent session ends.
        Task(name: "agent-session main-actor check-in") { [weak self] in
            while !Task.isCancelled {
                self?.heartbeat?.noteMainActorAlive()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Verbs

    func handle(action: String?, request: [String: Any]) async -> [String: Any] {
        switch action ?? "status" {
        case "status": await status()
        case "start": start()
        case "stop": await stop(reason: "session stop")
        default: ["ok": false, "error": "session takes enable, start, stop, or status"]
        }
    }

    /// Starts the session in the background and answers at once with `state: starting`; the
    /// CLI follows progress through `status`. A start takes longer than one socket request
    /// may, and the daemon serves one request at a time.
    func start() -> [String: Any] {
        if case .starting = phase { return ["ok": true, "state": "starting", "progress": progress, "summary": "already starting"] }
        if case .running = phase, heartbeat?.isArmed == true {
            return ["ok": true, "state": "running", "summary": "the agent session is already running"]
        }
        if EmergencyStop.isHalted {
            return ["ok": false, "error": EmergencyStop.refusalMessage, "halted": true]
        }
        guard AgentSessionLink.hasKeys else {
            return ["ok": false, "error": AgentSessionLink.LinkError.notEnabled.description]
        }
        guard let route = makeBringUp?() else {
            return ["ok": false, "error": "no way to create an off-console session is available on this Mac — see Docs/AGENT-SESSION.md"]
        }
        phase = .starting
        progress = []
        generation += 1
        let mine = generation
        startTask = Task(name: "agent-session start") { [weak self] in
            await self?.runStart(route: route, generation: mine)
        }
        return ["ok": true, "state": "starting", "progress": progress, "summary": "starting the agent session"]
    }

    private func runStart(route: any AgentSessionBringUp, generation mine: Int) async {
        let account = account
        let link = link
        func note(_ line: String) {
            guard generation == mine else { return }
            progress.append(line)
        }
        /// False once a stop, a halt, or a newer start has overtaken this one. Whatever this
        /// start brought up is then ended here, and nothing is committed.
        func stillWanted() async -> Bool {
            guard generation != mine || Task.isCancelled || EmergencyStop.isHalted else { return true }
            heartbeatInFlight?.stopNow()
            heartbeatInFlight = nil
            route.close()
            if let uid = Self.uid(of: account), Self.loginWindow(of: uid) != nil {
                _ = await link.call("stop")
            }
            if generation == mine { phase = .idle }
            return false
        }
        func fail(_ message: String) async {
            guard generation == mine else { return }
            note("failed: \(message)")
            // A session that came up without its switch armed must not outlive this failure.
            if let uid = Self.uid(of: account), Self.loginWindow(of: uid) != nil {
                note("ending the half-started session")
                _ = await link.call("stop")
            }
            heartbeat?.close()
            heartbeat = nil
            route.close()
            bringUp = nil
            phase = .failed(message)
            record?("session start", "failed", message)
        }

        guard let uid = Self.uid(of: account) else { return await fail("there is no '\(account)' account — rocuronium session enable") }
        if Self.loginWindow(of: uid) != nil {
            return await fail("'\(account)' already has a session this daemon did not start; stop it first (rocuronium session stop)")
        }
        guard let password = AgentSessionKeychain.password(account: account) else {
            return await fail("no stored password for '\(account)' — rocuronium session enable")
        }
        bringUp = route
        note("requesting an off-console session for \(account) (\(route.route))")
        do {
            try await route.open(account: account, password: password) { [weak self] line in
                guard self?.generation == mine else { return }
                self?.progress.append(line)
            }
        } catch {
            return await fail("\(error)")
        }
        guard await stillWanted() else { return }
        let appeared = Date()
        while Self.loginWindow(of: uid) == nil {
            guard Date().timeIntervalSince(appeared) < Constants.sessionAppearTimeout else {
                return await fail("no session for \(account) appeared within \(Int(Constants.sessionAppearTimeout)) s")
            }
            try? await Task.sleep(for: .milliseconds(500))
            guard await stillWanted() else { return }
        }
        note("session is up (loginwindow pid \(Self.loginWindow(of: uid) ?? 0)) after \(String(format: "%.1f", Date().timeIntervalSince(appeared))) s")

        // No unattended session without a kill path: arm the switch before anything else runs.
        let switchBox = AgentSessionHeartbeat()
        heartbeatInFlight = switchBox
        switchBox.onEnded = { [weak self] reason in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.switchEnded(reason) } }
        }
        do {
            try await switchBox.arm(link: link)
        } catch {
            heartbeatInFlight = nil
            return await fail("\(error)")
        }
        guard await stillWanted() else { return }
        heartbeatInFlight = nil
        heartbeat = switchBox
        note("dead-man's switch armed (\(AgentSessionHeartbeat.Constants.deadlineSeconds) s deadline)")

        _ = await link.call("start-daemon")
        let waiting = Date()
        var daemon: [String: Any]?
        while daemon == nil, Date().timeIntervalSince(waiting) < Constants.daemonAnswerTimeout {
            if case let .success(reply) = await link.forward(["command": "status"]), reply["ok"] as? Bool == true {
                daemon = reply
            } else {
                try? await Task.sleep(for: .seconds(1))
            }
            guard await stillWanted() else { return }
        }
        guard let daemon else { return await fail("Rocuronium did not answer inside the session within \(Int(Constants.daemonAnswerTimeout)) s") }
        guard daemon["offConsole"] as? Bool == true else {
            return await fail("the daemon inside the session reports offConsole = false — refusing to drive it")
        }
        guard await stillWanted() else { return }
        note("Rocuronium answers inside the session (offConsole: true, accessibility \(daemon["trusted"] as? Bool == true ? "granted" : "NOT granted"))")
        phase = .running(since: Date())
        record?("session start", "ok", "agent session for \(account) is running")
    }

    /// Ends the session: the watcher's own bootout via `stop`, then a direct SSH bootout, and
    /// then a check that the account's processes are gone. The one path allowed to precede an
    /// account deletion.
    func stop(reason: String) async -> [String: Any] {
        generation += 1
        startTask?.cancel()
        heartbeatInFlight?.stopNow()
        heartbeatInFlight = nil
        let account = account
        var lines: [String] = []
        if let heartbeat {
            heartbeat.stopNow()
            lines.append("stop sent down the dead-man's switch")
        }
        heartbeat = nil
        bringUp?.close()
        bringUp = nil
        guard let uid = Self.uid(of: account) else {
            phase = .idle
            return ["ok": true, "state": "idle", "lines": lines, "summary": "no '\(account)' account, so no session"]
        }
        if Self.loginWindow(of: uid) != nil {
            switch await link.call("stop") {
            case let .success(reply): lines.append("bootout over ssh: exit \(reply["status"] ?? "?")")
            case let .failure(error): lines.append("bootout over ssh failed: \(error)")
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while Self.loginWindow(of: uid) != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let survivor = Self.loginWindow(of: uid)
        phase = survivor == nil ? .idle : .failed("the session survived the bootout")
        record?(reason, survivor == nil ? "ok" : "failed", survivor == nil ? "agent session for \(account) ended" : "the session survived the bootout")
        return [
            "ok": survivor == nil,
            "state": survivor == nil ? "idle" : "failed",
            "lines": lines,
            "summary": survivor == nil ? "the agent session is stopped" : "the session for \(account) is still running (loginwindow pid \(survivor!))",
        ]
    }

    /// ⌃⌥⇧⎋ on the console: the chord is session-scoped and never reaches the agent session's
    /// own daemon, so this side ends that session for it.
    func emergencyStop() {
        guard heartbeat != nil || heartbeatInFlight != nil || bringUp != nil || phase == .starting else { return }
        Task(name: "agent-session emergency stop") { await stop(reason: "⌃⌥⇧⎋") }
    }

    /// The watcher's ssh exited. If it bootouted, the session is gone; if it died some other
    /// way, the session is unguarded and is ended from here.
    private func switchEnded(_ reason: String) {
        guard heartbeat != nil else { return }
        heartbeat = nil
        record?("dead-man's switch", "fired", reason)
        Task(name: "agent-session switch ended") { _ = await stop(reason: "dead-man's switch: \(reason)") }
    }

    func status() async -> [String: Any] {
        let account = account
        var reply: [String: Any] = ["ok": true, "account": account, "state": stateWord, "progress": progress]
        var lines: [String] = []
        guard let uid = Self.uid(of: account) else {
            lines.append("account     \(account): not provisioned — rocuronium session enable")
            reply["lines"] = lines
            reply["provisioned"] = false
            return reply
        }
        reply["uid"] = Int(uid)
        reply["provisioned"] = AgentSessionLink.hasKeys
        lines.append("account     \(account) (uid \(uid))\(AgentSessionLink.hasKeys ? "" : " — not enabled for this daemon")")
        let loginWindow = Self.loginWindow(of: uid)
        reply["sessionExists"] = loginWindow != nil
        if let loginWindow {
            let uptime = Self.startDate(of: loginWindow).map { Int(Date().timeIntervalSince($0)) }
            reply["uptimeSeconds"] = uptime
            lines.append("session     up \(uptime.map(Self.duration) ?? "?") (loginwindow pid \(loginWindow))")
        } else {
            lines.append("session     none")
        }
        lines.append("state       \(stateWord)" + (bringUp.map { " via \($0.route)\($0.isHeld ? ", viewer held" : ", viewer gone — curtained")" } ?? ""))
        reply["switchArmed"] = heartbeat?.isArmed == true
        lines.append("switch      " + (heartbeat.map { $0.isArmed ? "armed, \($0.beats) beats" : "not armed" } ?? "none"))

        if loginWindow != nil, AgentSessionLink.hasKeys {
            if case let .success(facts) = await link.call("facts", timeout: 8) {
                let displays = facts["displays"] as? [[String: Any]] ?? []
                reply["displays"] = displays
                reply["sessionOnConsole"] = facts["onConsole"]
                lines.append("displays    " + (displays.isEmpty ? "none" : displays.map { "\($0["w"] ?? "?")×\($0["h"] ?? "?") @(\($0["x"] ?? "?"),\($0["y"] ?? "?")) id \($0["id"] ?? "?")" }.joined(separator: ", ")))
            }
            switch await link.forward(["command": "status"], timeout: 8) {
            case let .success(daemon) where daemon["ok"] as? Bool == true:
                reply["daemonAnswers"] = true
                reply["offConsole"] = daemon["offConsole"]
                reply["daemonTrusted"] = daemon["trusted"]
                lines.append("daemon      answers — \(daemon["version"] ?? "?"), offConsole \(daemon["offConsole"] as? Bool == true), accessibility \(daemon["trusted"] as? Bool == true ? "granted" : "NOT granted")")
            case let .success(daemon):
                reply["daemonAnswers"] = false
                lines.append("daemon      silent (\(daemon["error"] ?? "no reply"))")
            case let .failure(error):
                reply["daemonAnswers"] = false
                lines.append("daemon      unreachable: \(error)")
            }
        }
        if case let .failed(message) = phase { reply["lastError"] = message }
        reply["lines"] = lines
        return reply
    }

    private var stateWord: String {
        switch phase {
        case .idle: "idle"
        case .starting: "starting"
        case .running: "running"
        case .failed: "failed"
        }
    }

    // MARK: - Process table

    static func uid(of account: String) -> uid_t? {
        guard let entry = getpwnam(account) else { return nil }
        return entry.pointee.pw_uid
    }

    /// Each GUI login session, console or off-console, has exactly one loginwindow, running as
    /// its user — the cheapest unprivileged test for "this account has a session".
    /// (`launchctl print gui/<uid>` answers only for one's own uid.)
    static func loginWindow(of uid: uid_t) -> pid_t? {
        let capacity = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size + 32)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return nil }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).first { pid in
            var name = [CChar](repeating: 0, count: 64)
            return pid > 0 && proc_name(pid, &name, UInt32(name.count)) > 0 && String(cString: name) == "loginwindow"
        }
    }

    static func startDate(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    static func duration(_ seconds: Int) -> String {
        seconds < 120 ? "\(seconds) s" : seconds < 7200 ? "\(seconds / 60) min" : "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }
}

/// The agent account's password, in the console user's login keychain. Created by this app,
/// so this app reads it without a prompt; nothing else does without the human's consent.
nonisolated enum AgentSessionKeychain {
    static let service = "glass.kagerou.rocuronium.agent-session"

    static func password(account: String) -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func store(password: String, account: String) -> OSStatus {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(password.utf8)
        let updated = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Rocuronium agent session (\(account))"
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// 32 characters from a 57-symbol alphabet with no look-alikes, from `SecRandomCopyBytes`
    /// with the modulo bias rejected: ~186 bits, and nothing a pty or a prompt could misread.
    static func generatePassword() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.filter { Int($0) < 256 - 256 % alphabet.count }.prefix(32).map { alphabet[Int($0) % alphabet.count] })
    }
}
