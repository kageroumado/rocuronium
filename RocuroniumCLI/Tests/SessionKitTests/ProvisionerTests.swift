import Darwin
import Foundation
import Testing
@testable import SessionKit

struct ProvisionerTests {
    /// Records every argv; succeeds at everything, and creates the account when sysadminctl
    /// is asked to.
    final class RecordingRunner: CommandRunner, @unchecked Sendable {
        var argvs: [[String]] = []
        var inputs: [Data] = []
        var authenticates = true
        let system: AccountRemovalTests.FakeSystem

        init(system: AccountRemovalTests.FakeSystem) {
            self.system = system
        }

        func run(_ executable: String, _ arguments: [String], input: Data?) -> CommandResult {
            argvs.append([executable] + arguments)
            if let input { inputs.append(input) }
            return CommandResult(status: 0, output: executable.hasSuffix("sw_vers") ? "27.0.1\n" : "")
        }

        func answeringPrompt(_: String, with _: String, argv: [String]) -> CommandResult {
            argvs.append(argv)
            if argv.contains("-addUser") { system.accounts["agent"] = 503 }
            if argv.contains("-authonly") { return CommandResult(status: authenticates ? 0 : 1, output: "") }
            return CommandResult(status: 0, output: "")
        }
    }

    private static let secret = "correct-horse-battery-staple"

    private static func request(password: String = secret) -> ProvisioningRequest {
        ProvisioningRequest(
            name: "agent", fullName: "Agent", password: password,
            authorizedKey: "ssh-ed25519 AAAATEST console@mac", appPath: "/Applications/Rocuronium.app",
        )
    }

    /// argv is world-readable through `ps`; the password must reach every tool some other way.
    @Test func thePasswordNeverReachesArgv() {
        let system = AccountRemovalTests.FakeSystem()
        system.accounts = [:]
        let runner = RecordingRunner(system: system)
        let outcome = Provisioner(runner: runner, system: system).run(Self.request(), protecting: 501)
        guard case let .provisioned(uid, created, _) = outcome else {
            Issue.record("expected provisioning, got \(outcome)")
            return
        }
        #expect(uid == 503 && created)
        for argv in runner.argvs {
            #expect(!argv.joined(separator: " ").contains(Self.secret), "password on argv: \(argv)")
        }
        for input in runner.inputs {
            #expect(!String(decoding: input, as: UTF8.self).contains(Self.secret))
        }
    }

    @Test func neverCreatesAnAdministrator() {
        let system = AccountRemovalTests.FakeSystem()
        system.accounts = [:]
        let runner = RecordingRunner(system: system)
        _ = Provisioner(runner: runner, system: system).run(Self.request(), protecting: 501)
        let creation = runner.argvs.first { $0.contains("-addUser") }
        #expect(creation != nil)
        #expect(creation?.contains("-admin") == false)
    }

    @Test func aWrongPasswordForAnExistingAccountIsRefusedBeforeAnythingIsWritten() {
        let system = AccountRemovalTests.FakeSystem()
        let runner = RecordingRunner(system: system)
        runner.authenticates = false
        let outcome = Provisioner(runner: runner, system: system).run(Self.request(), protecting: 501)
        guard case .refused = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(!runner.argvs.contains { $0.contains("/usr/bin/tee") || $0.contains("/usr/sbin/dseditgroup") })
    }

    @Test func aShortPasswordNeverCreatesAnAccount() {
        let system = AccountRemovalTests.FakeSystem()
        system.accounts = [:]
        let runner = RecordingRunner(system: system)
        guard case .refused = Provisioner(runner: runner, system: system).run(Self.request(password: "1234"), protecting: 501) else {
            Issue.record("a four-character password created an account")
            return
        }
        #expect(runner.argvs.isEmpty)
    }

    @Test func everyHomeWriteRunsAsTheAccount() {
        let system = AccountRemovalTests.FakeSystem()
        let runner = RecordingRunner(system: system)
        _ = Provisioner(runner: runner, system: system).run(Self.request(), protecting: 501)
        for argv in runner.argvs where argv.contains(where: { $0.contains("/Users/") || $0.hasPrefix("/var/") }) {
            #expect(argv.first == "/usr/bin/sudo" && argv[1] == "-u" && argv[2] == "agent", "home write as root: \(argv)")
        }
    }

    @Test func theKeyLineIsForcedAndReplacesItsPredecessor() {
        let existing = """
            ssh-ed25519 AAAAHUMAN kiri@laptop
            restrict,command="/old/rocuronium session remote" ssh-ed25519 AAAAOLD rocuronium-agent-session
            """
        let keys = Templates.authorizedKeys(existing: existing, publicKey: "ssh-ed25519 AAAANEW kirie@studio", cliPath: "/Applications/Rocuronium.app/Contents/Resources/rocuronium")
        #expect(keys.contains("ssh-ed25519 AAAAHUMAN kiri@laptop"))
        #expect(!keys.contains("AAAAOLD"))
        #expect(keys.contains(#"restrict,command="/Applications/Rocuronium.app/Contents/Resources/rocuronium session remote" ssh-ed25519 AAAANEW rocuronium-agent-session"#))
        #expect(!keys.contains("kirie@studio"), "the console user's key comment leaks a name into the agent account")
    }

    @Test func theWallpaperTemplateIsTheCapturedPlist() throws {
        let plist = try PropertyListSerialization.propertyList(from: Templates.blackWallpaperIndex, format: nil)
        let text = String(describing: plist)
        #expect(text.contains("com.apple.wallpaper.choice.color"))
    }
}
