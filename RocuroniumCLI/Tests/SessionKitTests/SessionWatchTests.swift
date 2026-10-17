import Foundation
import Testing
@testable import SessionKit

/// The dead-man's switch: inside the agent account, a watcher reads heartbeats that the
/// console-side daemon writes down an SSH pipe, and ends the session when they stop. Every
/// way the console side can disappear — a crash, a quit, a hung link, ⌃⌥⇧⎋ — has to arrive
/// here as a bootout, and nothing else may.
struct SessionWatchTests {
    @Test func beatsKeepTheSessionAlive() {
        #expect(SessionWatch.verdict(for: .line("beat")) == .keepWatching)
        #expect(SessionWatch.verdict(for: .line("beat 1760000000")) == .keepWatching)
    }

    @Test func silenceEndsTheSession() {
        guard case .bootout = SessionWatch.verdict(for: .timeout) else {
            Issue.record("a missed deadline must end the session")
            return
        }
    }

    /// The console daemon died, quit, or closed the pipe on purpose: the read end sees EOF.
    @Test func aClosedPipeEndsTheSession() {
        guard case .bootout = SessionWatch.verdict(for: .endOfInput) else {
            Issue.record("EOF must end the session")
            return
        }
    }

    /// ⌃⌥⇧⎋ on the console writes `stop`, so the chord ends this session without waiting out
    /// the deadline.
    @Test func stopEndsTheSessionImmediately() {
        #expect(SessionWatch.verdict(for: .line("stop")) == .bootout(reason: "stopped from the console"))
    }

    /// Anything unrecognized is a broken console side, not a beat; failing closed means the
    /// session ends rather than living on noise.
    @Test func garbageEndsTheSession() {
        guard case .bootout = SessionWatch.verdict(for: .line("hello")) else {
            Issue.record("an unknown line must end the session")
            return
        }
    }

    /// The watcher bootouts its own uid's GUI domain. Run in the human's console session that
    /// would log the human out, so it refuses to arm anywhere but off-console — and an
    /// unreadable session counts as on-console.
    @Test func armsOnlyOffConsole() {
        #expect(SessionWatch.armingRefusal(onConsole: false) == nil)
        #expect(SessionWatch.armingRefusal(onConsole: true) != nil)
        #expect(SessionWatch.armingRefusal(onConsole: nil) != nil)
    }

    @Test func deadlinesAreBounded() {
        #expect(SessionWatch.deadline(requested: nil) == SessionWatch.defaultDeadlineSeconds)
        #expect(SessionWatch.deadline(requested: 0) == SessionWatch.minimumDeadlineSeconds)
        #expect(SessionWatch.deadline(requested: 99999) == SessionWatch.maximumDeadlineSeconds)
        #expect(SessionWatch.deadline(requested: 20) == 20)
    }
}

/// What rocuronium's SSH key may run inside the agent account. The key is installed with a
/// forced command, so the remote side gets `SSH_ORIGINAL_COMMAND` and nothing else.
struct RemoteCommandTests {
    @Test func knownCommandsParse() {
        #expect(RemoteCommand.parse("watch") == .watch(deadlineSeconds: nil))
        #expect(RemoteCommand.parse("watch 15") == .watch(deadlineSeconds: 15))
        #expect(RemoteCommand.parse("watch-login") == .watchLogin(deadlineSeconds: nil))
        #expect(RemoteCommand.parse("watch-login 15") == .watchLogin(deadlineSeconds: 15))
        #expect(RemoteCommand.parse("watch-login now") == nil)
        #expect(RemoteCommand.parse("stop") == .stop)
        #expect(RemoteCommand.parse("facts") == .facts)
        #expect(RemoteCommand.parse("forward") == .forward)
        #expect(RemoteCommand.parse("start-daemon") == .startDaemon)
        #expect(RemoteCommand.parse("restart-daemon") == .restartDaemon)
        #expect(RemoteCommand.parse("restart-daemon extra") == nil)
    }

    /// A login shell is exactly what the forced command exists to withhold.
    @Test func shellsAndUnknownsAreRefused() {
        #expect(RemoteCommand.parse(nil) == nil)
        #expect(RemoteCommand.parse("") == nil)
        #expect(RemoteCommand.parse("bash") == nil)
        #expect(RemoteCommand.parse("stop; rm -rf ~") == nil)
        #expect(RemoteCommand.parse("watch 15 extra") == nil)
        #expect(RemoteCommand.parse("watch abc") == nil)
    }
}

/// The switch armed before the login exists. It must end a session that appears after the
/// console side is gone, and must never end one at the physical console.
struct PendingLoginWatchTests {
    private func session(uid: Int, onConsole: Bool?) -> [String: Any] {
        var entry: [String: Any] = ["kCGSSessionUserIDKey": NSNumber(value: uid)]
        if let onConsole { entry["kCGSSessionOnConsoleKey"] = NSNumber(value: onConsole) }
        return entry
    }

    /// The console-user record listed after a Screen Sharing agent login: the human on the
    /// console, the agent off it.
    @Test func readsTheAccountsOwnSessionOnly() {
        let sessions = [session(uid: 502, onConsole: false), session(uid: 501, onConsole: true)]
        #expect(PendingLoginWatch.onConsole(sessions: sessions, uid: 502) == false)
        #expect(PendingLoginWatch.onConsole(sessions: sessions, uid: 501) == true)
    }

    @Test func anOnConsoleSessionOfTheAccountWins() {
        let sessions = [session(uid: 502, onConsole: false), session(uid: 502, onConsole: true)]
        #expect(PendingLoginWatch.onConsole(sessions: sessions, uid: 502) == true)
    }

    /// A session without the key cannot be shown to be off-console, so it counts as on it.
    @Test func aSessionWithoutTheKeyCountsAsOnConsole() {
        #expect(PendingLoginWatch.onConsole(sessions: [session(uid: 502, onConsole: nil)], uid: 502) == true)
    }

    @Test func noListedSessionIsUnknown() {
        #expect(PendingLoginWatch.onConsole(sessions: [], uid: 502) == nil)
        #expect(PendingLoginWatch.onConsole(sessions: [session(uid: 501, onConsole: true)], uid: 502) == nil)
    }

    /// A console side that vanished may have a login on its way; one that stopped on purpose
    /// verifies its own cleanup, and a long wait would catch the next start's login.
    @Test func onlyAnAbandonedWatchWaitsForTheLogin() {
        #expect(PendingLoginWatch.loginWait(after: .endOfInput) == PendingLoginWatch.loginWaitSeconds)
        #expect(PendingLoginWatch.loginWait(after: .timeout) == PendingLoginWatch.loginWaitSeconds)
        #expect(PendingLoginWatch.loginWait(after: .line("hello")) == PendingLoginWatch.loginWaitSeconds)
        #expect(PendingLoginWatch.loginWait(after: .line("stop")) == PendingLoginWatch.stopListingSeconds)
    }
}
