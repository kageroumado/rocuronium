import Foundation
import Testing
@testable import SessionKit

struct PasswordPromptTests {
    @Test func sendsPasswordThroughATerminalAndPreservesExitStatus() {
        let secret = "-test {braces} $dollar [brackets] \\slash"
        let child = """
            /bin/stty -echo
            printf 'Password:'
            IFS= read -r reply
            test "$reply" = "$ROCURONIUM_SECRET" || exit 7
            exit 23
            """
        let result = Shell.answeringPrompt(
            "Password:", with: secret,
            argv: ["/bin/sh", "-c", child], timeout: 3,
        )
        #expect(result.status == 23)
        #expect(result.output.contains(secret) == false)
    }

    @Test func successfulPasswordPromptReturnsSuccess() {
        let child = "/bin/stty -echo; printf 'Password:'; IFS= read -r reply; test \"$reply\" = \"$ROCURONIUM_SECRET\""
        let result = Shell.answeringPrompt(
            "Password:", with: "test credential", argv: ["/bin/sh", "-c", child], timeout: 3,
        )
        #expect(result.succeeded)
        #expect(result.output.isEmpty)
    }
}
