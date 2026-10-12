import Foundation
import Testing
@testable import rocuronium

struct PasswordInputTests {
    @Test(arguments: ["- spaces $[]{}\\ ", "日本語", "leading\nnewline"])
    func preservesPasswordContent(_ value: String) throws {
        #expect(try PasswordInput.decode(Data((value + "\n").utf8)) == value)
        #expect(try PasswordInput.decode(Data((value + "\r\n").utf8)) == value)
    }

    @Test func rejectsEmptyAndInvalidInput() {
        #expect(throws: PasswordInput.InputError.empty) { try PasswordInput.decode(Data("\n".utf8)) }
        #expect(throws: PasswordInput.InputError.invalidEncoding) { try PasswordInput.decode(Data([0xff])) }
    }
}
