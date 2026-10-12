import Darwin
import Foundation
import Testing
@testable import Rocuronium

struct SessionProcessTableTests {
    @Test func currentProcessHasIdentityAndStartTime() throws {
        let entry = try #require(SessionProcessTable.entries(ownedBy: getuid()).first { $0.pid == getpid() })
        #expect(entry.name.isEmpty == false)
        #expect(entry.started <= Date())
        #expect(entry.started > Date(timeIntervalSince1970: 0))
    }

    @Test func crossUserRootProcessIsReadable() throws {
        let launchd = try #require(SessionProcessTable.entries(ownedBy: 0).first { $0.pid == 1 })
        #expect(launchd.name == "launchd")
        #expect(launchd.started < Date())
    }

    @Test func unusedUIDHasNoSession() throws {
        #expect(try SessionProcessTable.loginWindow(of: 4_000_000_000) == nil)
    }
}
