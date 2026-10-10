import Foundation
import Testing
@testable import rocuronium

/// An MCP server that outlived its install must say so, naming where it runs from; a current
/// one must stay silent, or every ordinary failure would be blamed on a reinstall.
struct StaleInstallTests {
    private static let installed = "/Applications/Rocuronium.app/Contents/Resources/rocuronium"
    private static let trashed = "/Users/someone/.Trash/Rocuronium.app/Contents/Resources/rocuronium"

    @Test func currentInstallIsNotStale() {
        #expect(StaleInstall.diagnosis(executablePath: Self.installed, diskMatchesRunningCode: true) == nil)
    }

    @Test func trashedBundleIsStaleAndNamed() throws {
        let message = try #require(StaleInstall.diagnosis(executablePath: Self.trashed, diskMatchesRunningCode: true))
        #expect(message.contains(Self.trashed))
        #expect(message.contains("/mcp"))
    }

    @Test func replacedBytesAreStaleEvenAtTheInstalledPath() throws {
        let message = try #require(StaleInstall.diagnosis(executablePath: Self.installed, diskMatchesRunningCode: false))
        #expect(message.contains(Self.installed))
    }

    @Test func deletedExecutableIsStale() {
        #expect(StaleInstall.diagnosis(executablePath: nil, diskMatchesRunningCode: true) != nil)
        #expect(StaleInstall.diagnosis(executablePath: "", diskMatchesRunningCode: true) != nil)
    }

    @Test func trashDetectionMatchesWholeComponents() {
        #expect(StaleInstall.isInTrash(Self.trashed))
        #expect(StaleInstall.isInTrash("/Volumes/External/.Trashes/501/Rocuronium.app/Contents/Resources/rocuronium"))
        #expect(!StaleInstall.isInTrash("/Users/someone/Trash-notes/rocuronium"))
        #expect(!StaleInstall.isInTrash(Self.installed))
    }

    @Test func thisTestProcessIsNotStale() {
        #expect(StaleInstall.diagnosis() == nil)
    }
}
