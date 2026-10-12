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
    /// Requests the session and awaits the OS acknowledgment. A canceled caller awaits this
    /// bounded operation before cleaning up any session the OS created.
    func open(account: String, password: String, progress: @escaping @MainActor (String) -> Void) async throws
    func close()
}

/// Owns one agent account's session, startup recovery, and the running session's watchdog.
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
        case stopping
        case running(since: Date)
        case failed(String)
    }

    struct Runtime {
        var enabled: (String) -> Bool
        var uid: (String) -> uid_t?
        var loginWindow: (uid_t) throws -> pid_t?
        var password: (String) async -> String?
        var endSession: (AgentSessionLink) async -> Result<[String: Any], AgentSessionLink.LinkError>
        var loadPendingLogin: () throws -> PendingAgentLogin? = { nil }
        var savePendingLogin: (PendingAgentLogin?) throws -> Void = { _ in }
        var now: () -> Date = { Date() }
        var recoveryPause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }

        static var live: Self {
            Self(
                enabled: { AgentSessionLink.hasKeys && UserDefaults.standard.string(forKey: Constants.accountKey) == $0 },
                uid: AgentSessionController.uid,
                loginWindow: AgentSessionController.loginWindow,
                password: { account in
                    await Task.detached(name: "agent session credential") {
                        AgentSessionKeychain.password(account: account)
                    }.value
                },
                endSession: { await $0.call("stop") },
                loadPendingLogin: PendingAgentLogin.load,
                savePendingLogin: PendingAgentLogin.save
            )
        }
    }

    private let runtime: Runtime
    private var stopTask: Task<Void, Never>?
    private var pendingLogin: PendingAgentLogin?
    private var recoveryLoadError: String?
    private enum Constants {
        static let accountKey = "agentSession.account"
        static let defaultAccount = "agent"
        /// Covers the handshake and subsequent loginwindow-appearance bounds.
        static let pendingLoginObservation: TimeInterval = 90
        /// From the request to the account's loginwindow existing; the measured spawn is ~10 s.
        static let sessionAppearTimeout: TimeInterval = 45
        /// From loginwindow to the daemon inside answering on its socket.
        static let daemonAnswerTimeout: TimeInterval = 40
    }

    private(set) var phase: Phase = .idle {
        didSet { if phase == .idle { releaseEmergencyShortcut?() } }
    }
    /// The console shortcut is held until shutdown reaches verified idle, including failed cleanup.
    var retainEmergencyShortcut: (() throws -> Void)?
    var releaseEmergencyShortcut: (() -> Void)?
    var emergencyShortcutRegistered: (() -> Bool)?
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
    /// Builds a fresh loopback viewer for each start.
    var makeBringUp: (@MainActor () -> (any AgentSessionBringUp)?)? = { AgentRFBBringUp() }
    /// Records start, stop, and the switch firing in the activity log.
    var record: (@MainActor (_ action: String, _ verdict: String, _ summary: String) -> Void)?

    var account: String {
        UserDefaults.standard.string(forKey: Constants.accountKey) ?? Constants.defaultAccount
    }

    var isEnabled: Bool {
        runtime.enabled(account)
    }

    var link: AgentSessionLink { AgentSessionLink(account: account) }

    init(runtime: Runtime = .live) {
        self.runtime = runtime
        do {
            pendingLogin = try runtime.loadPendingLogin()
            if pendingLogin != nil {
                phase = .stopping
                progress = ["recovering an interrupted agent login"]
                stopTask = Task(name: "recover interrupted agent login") { [weak self] in
                    guard let self else { return }
                    try? self.retainEmergencyShortcut?()
                    _ = await self.finishStop(reason: "interrupted startup recovery")
                    self.stopTask = nil
                }
            }
        } catch {
            recoveryLoadError = "could not read pending agent login: \(error)"
            phase = .failed(recoveryLoadError!)
        }
        // Proof of life for the heartbeat thread: if the main actor stops reaching this, the
        // beats stop and the agent session ends.
        Task(name: "agent-session main-actor check-in") { [weak self] in
            while !Task.isCancelled, self != nil {
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
        guard phase != .stopping else {
            return ["ok": false, "state": "stopping", "error": "the agent session is still stopping; wait for idle before starting again"]
        }
        if let recoveryLoadError { return ["ok": false, "error": recoveryLoadError] }
        if pendingLogin != nil, case .failed = phase {
            return ["ok": false, "error": "an interrupted login still needs cleanup — run rocuronium session stop"]
        }
        if case .starting = phase { return ["ok": true, "state": "starting", "progress": progress, "summary": "already starting"] }
        if case .running = phase, heartbeat?.isArmed == true {
            return ["ok": true, "state": "running", "summary": "the agent session is already running"]
        }
        if EmergencyStop.isHalted {
            return ["ok": false, "error": EmergencyStop.refusalMessage, "halted": true]
        }
        guard isEnabled else {
            return ["ok": false, "error": AgentSessionLink.LinkError.notEnabled.description]
        }
        guard let route = makeBringUp?() else {
            return ["ok": false, "error": "no way to create an off-console session is available on this Mac — see Docs/AGENT-SESSION.md"]
        }
        do { try retainEmergencyShortcut?() }
        catch { return ["ok": false, "error": String(describing: error)] }
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
        var requestedSession = false
        var startupHeartbeat: AgentSessionHeartbeat?
        func note(_ line: String) {
            guard generation == mine else { return }
            progress.append(line)
        }
        /// False once a stop, a halt, or a newer start has overtaken this one. Whatever this
        /// start brought up is then ended here, and nothing is committed.
        func stillWanted() async -> Bool {
            guard generation != mine || Task.isCancelled || EmergencyStop.isHalted else { return true }
            startupHeartbeat?.stopNow()
            route.close()
            if requestedSession {
                do { try await cleanPendingLogin() }
                catch { note("pending-login cleanup requires retry: \(error)") }
            }
            if generation == mine { phase = .idle }
            return false
        }
        func fail(_ message: String) async {
            guard generation == mine else { return }
            note("failed: \(message)")
            route.close()
            var failure = message
            // A session that came up without its switch armed must not outlive this failure.
            if requestedSession {
                note("ending the half-started session")
                do {
                    try await cleanPendingLogin()
                    note("failed-start cleanup verified: agent loginwindow is gone")
                } catch {
                    failure += "; could not verify failed-start cleanup: \(error)"
                }
            }
            guard generation == mine else { return }
            heartbeat?.close()
            heartbeat = nil
            bringUp = nil
            phase = .failed(failure)
            record?("session start", "failed", failure)
        }

        do {
            guard let uid = runtime.uid(account) else { return await fail("there is no '\(account)' account — rocuronium session enable") }
            if try runtime.loginWindow(uid) != nil {
                return await fail("'\(account)' already has a session this daemon did not start; stop it first (rocuronium session stop)")
            }
            let storedPassword = await runtime.password(account)
            guard await stillWanted() else { return }
            guard let password = storedPassword else {
                return await fail("no stored password for '\(account)' — rocuronium session enable")
            }
            bringUp = route
            if let viewer = route as? AgentRFBBringUp {
                viewer.onDisconnected = { [weak self] reason in
                    guard let self, self.generation == mine else { return }
                    Task(name: "agent viewer disconnected") {
                        guard self.generation == mine else { return }
                        _ = await self.stop(reason: "Screen Sharing: \(reason)")
                    }
                }
            }
            note("requesting an off-console session for \(account) (\(route.route))")
            do {
                let pending = PendingAgentLogin(account: account, uid: uid,
                                                observationDeadline: runtime.now().addingTimeInterval(Constants.pendingLoginObservation))
                try runtime.savePendingLogin(pending)
                pendingLogin = pending
                requestedSession = true
                try await route.open(account: account, password: password) { [weak self] line in
                    guard self?.generation == mine else { return }
                    self?.progress.append(line)
                }
            } catch {
                guard await stillWanted() else { return }
                return await fail("\(error)")
            }
            guard await stillWanted() else { return }
            let appeared = Date()
            while try runtime.loginWindow(uid) == nil {
                guard Date().timeIntervalSince(appeared) < Constants.sessionAppearTimeout else {
                    return await fail("no session for \(account) appeared within \(Int(Constants.sessionAppearTimeout)) s")
                }
                try? await Task.sleep(for: .milliseconds(500))
                guard await stillWanted() else { return }
            }
            note("session is up (loginwindow pid \(try runtime.loginWindow(uid) ?? 0)) after \(String(format: "%.1f", Date().timeIntervalSince(appeared))) s")

            // No unattended session without a kill path: arm the switch before anything else runs.
            let switchBox = AgentSessionHeartbeat()
            startupHeartbeat = switchBox
            heartbeatInFlight = switchBox
            switchBox.onEnded = { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.switchEnded(reason, generation: mine) } }
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
            try runtime.savePendingLogin(nil)
            pendingLogin = nil
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
        } catch {
            await fail("could not inspect the agent session: \(error)")
        }
    }

    /// Ends the GUI session through the watcher and restricted SSH, then verifies that its
    /// loginwindow is gone. Account removal separately drains remaining account processes.
    func stop(reason: String) async -> [String: Any] {
        if phase == .stopping { return stoppingReply }
        let pendingStart = phase == .starting && bringUp != nil ? startTask : nil
        phase = .stopping
        generation += 1
        startTask?.cancel()
        startTask = nil
        heartbeatInFlight?.stopNow()
        heartbeatInFlight = nil
        if let pendingStart {
            stopTask = Task(name: "finish pending agent login and stop") { [weak self] in
                await pendingStart.value
                guard let self else { return }
                _ = await self.finishStop(reason: reason)
                self.stopTask = nil
            }
            return stoppingReply
        }
        if pendingLogin != nil || recoveryLoadError != nil {
            stopTask = Task(name: "retry pending agent login cleanup") { [weak self] in
                guard let self else { return }
                _ = await self.finishStop(reason: reason)
                self.stopTask = nil
            }
            return stoppingReply
        }
        return await finishStop(reason: reason)
    }

    private var stoppingReply: [String: Any] {
        ["ok": true, "state": "stopping", "summary": "waiting for the pending login and verifying agent-session cleanup"]
    }

    private func finishStop(reason: String) async -> [String: Any] {
        let account = account
        var lines: [String] = []
        if let heartbeat {
            heartbeat.stopNow()
            lines.append("stop sent down the dead-man's switch")
        }
        heartbeat = nil
        bringUp?.close()
        bringUp = nil
        guard let uid = runtime.uid(account) else {
            if pendingLogin != nil || recoveryLoadError != nil {
                let message = "pending login account identity is unavailable; cleanup requires review"
                phase = .failed(message)
                return ["ok": false, "state": "failed", "error": message]
            }
            phase = .idle
            return ["ok": true, "state": "idle", "lines": lines, "summary": "no '\(account)' account, so no session"]
        }
        do {
            if recoveryLoadError != nil {
                pendingLogin = try runtime.loadPendingLogin()
                recoveryLoadError = nil
            }
            try await cleanPendingLogin()
            if try runtime.loginWindow(uid) != nil {
                switch await runtime.endSession(link) {
                case let .success(reply): lines.append("bootout over ssh: exit \(reply["status"] ?? "?")")
                case let .failure(error): lines.append("bootout over ssh failed: \(error)")
                }
            }
            let deadline = Date().addingTimeInterval(10)
            while try runtime.loginWindow(uid) != nil, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            let survivor = try runtime.loginWindow(uid)
            phase = survivor == nil ? .idle : .failed("the session survived the bootout")
            record?(reason, survivor == nil ? "ok" : "failed", survivor == nil ? "agent session for \(account) ended" : "the session survived the bootout")
            return [
                "ok": survivor == nil,
                "state": survivor == nil ? "idle" : "failed",
                "lines": lines,
                "summary": survivor == nil ? "the agent session is stopped" : "the session for \(account) is still running (loginwindow pid \(survivor!))",
            ]
        } catch {
            let message = "could not verify session shutdown: \(error)"
            phase = .failed(message)
            record?(reason, "failed", message)
            return ["ok": false, "state": "failed", "lines": lines, "error": message]
        }
    }

    /// Observes an unacknowledged login until it appears or its bounded recovery window ends.
    /// The saved record survives errors, so later stops and daemon restarts can retry cleanup.
    private func cleanPendingLogin() async throws {
        let saved = pendingLogin
        guard let uid = runtime.uid(account) else {
            if saved != nil { throw AgentRFBError("pending login account identity is unavailable") }
            return
        }
        let pending = saved ?? PendingAgentLogin(account: account, uid: uid, observationDeadline: runtime.now())
        guard pending.account == account, runtime.uid(pending.account) == pending.uid else {
            throw AgentRFBError("pending login belongs to a different account identity; cleanup requires review")
        }
        while try runtime.loginWindow(pending.uid) == nil, runtime.now() < pending.observationDeadline {
            try await runtime.recoveryPause()
        }
        if try runtime.loginWindow(pending.uid) != nil {
            _ = await runtime.endSession(AgentSessionLink(account: pending.account))
            let deadline = runtime.now().addingTimeInterval(10)
            while try runtime.loginWindow(pending.uid) != nil, runtime.now() < deadline {
                try await runtime.recoveryPause()
            }
            guard try runtime.loginWindow(pending.uid) == nil else {
                throw AgentRFBError("the agent session survived pending-login cleanup")
            }
        }
        if saved != nil {
            try runtime.savePendingLogin(nil)
            pendingLogin = nil
        }
    }

    /// ⌃⌥⇧⎋ on the console: the chord is session-scoped and never reaches the agent session's
    /// own daemon, so this side ends that session for it.
    func emergencyStop() {
        guard phase != .idle || heartbeat != nil || heartbeatInFlight != nil || bringUp != nil else { return }
        Task(name: "agent-session emergency stop") { await stop(reason: "⌃⌥⇧⎋") }
    }

    /// The watcher's ssh exited. If it bootouted, the session is gone; if it died some other
    /// way, the session is unguarded and is ended from here.
    private func switchEnded(_ reason: String, generation mine: Int) {
        guard generation == mine, heartbeat != nil else { return }
        heartbeat = nil
        record?("dead-man's switch", "fired", reason)
        Task(name: "agent-session switch ended") {
            guard generation == mine else { return }
            _ = await stop(reason: "dead-man's switch: \(reason)")
        }
    }

    func status() async -> [String: Any] {
        let account = account
        var reply: [String: Any] = ["ok": true, "account": account, "state": stateWord, "progress": progress]
        var lines: [String] = []
        guard let uid = runtime.uid(account) else {
            lines.append("account     \(account): not provisioned — rocuronium session enable")
            reply["lines"] = lines
            reply["provisioned"] = false
            return reply
        }
        reply["uid"] = Int(uid)
        reply["provisioned"] = isEnabled
        reply["keysPrepared"] = AgentSessionLink.hasKeys
        lines.append("account     \(account) (uid \(uid))\(isEnabled ? "" : " — not enabled for this daemon")")
        let session: SessionProcessTable.Entry?
        do {
            session = try SessionProcessTable.loginWindow(of: uid)
        } catch {
            reply["ok"] = false
            reply["error"] = "could not inspect the agent session: \(error)"
            reply["lines"] = lines + ["session     unknown — process lookup failed"]
            return reply
        }
        let loginWindow = session?.pid
        reply["sessionExists"] = session != nil
        if let session {
            // A loginwindow can wait at the user chooser before the account signs in.
            let processAge = max(0, Int(Date().timeIntervalSince(session.started)))
            reply["loginwindowAgeSeconds"] = processAge
            lines.append("session     running (loginwindow pid \(session.pid), process age \(Self.duration(processAge)))")
        } else {
            lines.append("session     none")
        }
        lines.append("state       \(stateWord)" + (bringUp.map { " via \($0.route)\($0.isHeld ? ", viewer held" : ", viewer gone — curtained")" } ?? ""))
        reply["emergencyShortcutRegistered"] = emergencyShortcutRegistered?() ?? false
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
        case .stopping: "stopping"
        case .running: "running"
        case .failed: "failed"
        }
    }

    // MARK: - Process table

    static func uid(of account: String) -> uid_t? {
        guard let entry = getpwnam(account) else { return nil }
        return entry.pointee.pw_uid
    }

    /// Reads the account's GUI session from cross-user BSD process metadata.
    static func loginWindow(of uid: uid_t) throws -> pid_t? {
        try SessionProcessTable.loginWindow(of: uid)?.pid
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
