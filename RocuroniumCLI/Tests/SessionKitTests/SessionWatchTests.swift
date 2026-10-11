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
        #expect(RemoteCommand.parse("stop") == .stop)
        #expect(RemoteCommand.parse("facts") == .facts)
        #expect(RemoteCommand.parse("forward") == .forward)
        #expect(RemoteCommand.parse("start-daemon") == .startDaemon)
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
