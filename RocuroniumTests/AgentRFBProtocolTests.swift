import Foundation
import Testing
@testable import Rocuronium

struct AgentRFBProtocolTests {
    private let prime = Data(hex: "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF")

    @Test func nativeDHAgreesBetweenIndependentPeers() throws {
        let alice = try AgentRFBDiffieHellman(generator: 2, prime: prime)
        let bob = try AgentRFBDiffieHellman(generator: 2, prime: prime)
        #expect(alice.publicKey.count == prime.count)
        #expect(alice.publicKey != bob.publicKey)
        #expect(try alice.encryptionKey(peer: bob.publicKey) == bob.encryptionKey(peer: alice.publicKey))
        #expect(throws: AgentRFBError.self) { try alice.encryptionKey(peer: Data(repeating: 0, count: prime.count)) }
    }

    @Test func aesMatchesNISTECBVector() throws {
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")
        let plain = Data(hex: "6bc1bee22e409f96e93d7e117393172a")
        #expect(try AgentRFBProtocol.encrypt(plain, key: key) == Data(hex: "3ad77bb40d7a3660a89ecaf32466ef97"))
    }

    @Test func credentialsAreTerminatedWithoutTruncation() throws {
        let data = try AgentRFBProtocol.credentials(account: "agent", password: "té st")
        #expect(data.count == 128)
        #expect(data.prefix(6) == Data("agent\0".utf8))
        #expect(data[64..<71] == Data("té st\0".utf8))
        #expect(throws: AgentRFBError.self) { try AgentRFBProtocol.credentials(account: "agent", password: String(repeating: "é", count: 32)) }
        #expect(throws: AgentRFBError.self) { try AgentRFBProtocol.credentials(account: "agent", password: "ab\0cd") }
    }

    @Test func selectionRequestsOnlyVirtualSession() throws {
        let encrypted = Data(repeating: 0xa5, count: 128)
        let message = try AgentRFBProtocol.selectVirtualSession(encryptedCredentials: encrypted)
        #expect(message.count == 202)
        #expect(message.prefix(10) == Data([0, 200, 0, 2, 0, 0, 0, 0, 2, 0]))
        #expect(message.suffix(128) == encrypted)
        #expect(message[10..<21] == Data("Rocuronium\0".utf8))
    }

    @Test func consoleOrMissingSelectionCapabilitiesAreRefused() throws {
        var name = Data(repeating: 0, count: 22)
        #expect(throws: AgentRFBError.self) { try AgentRFBProtocol.validateServerName(name) }
        name[5] = 4
        try AgentRFBProtocol.validateServerName(name)
        name[5] = 12
        #expect(throws: AgentRFBError.self) { try AgentRFBProtocol.validateServerName(name) }
        var info = Data(repeating: 0, count: 74)
        info[1] = 1
        info[5] = 3
        info[9] = 4
        #expect(throws: AgentRFBError.self) { try AgentRFBProtocol.validateSelectionInfo(info) }
        info[5] = 4
        info[9] = 0
        try AgentRFBProtocol.validateSelectionInfo(info)
        #expect(throws: AgentRFBError.self) { try AgentRFBProtocol.validateSelectionInfo(info.prefix(10)) }
    }

    @Test func refusedOrMalformedResultCannotBecomeSuccess() throws {
        var body = Data(repeating: 0, count: 80)
        body[1] = 1
        try AgentRFBProtocol.validateSelectionResult(body)
        body[5] = 74
        body[7] = 1
        try AgentRFBProtocol.validateSelectionResult(body)
        body[2] = 1
        #expect(throws: AgentRFBError.self) { try AgentRFBProtocol.validateSelectionResult(body) }
        #expect(throws: AgentRFBError.self) { try AgentRFBProtocol.validateSelectionResult(Data()) }
        body[2] = 0
        body[7] = 2
        #expect(throws: AgentRFBError.self) { try AgentRFBProtocol.validateSelectionResult(body) }
    }

    @Test func cancelledConnectionNeverOpens() {
        let connection = AgentRFBConnection()
        connection.cancel()
        connection.cancel()
        #expect(throws: CancellationError.self) { try connection.open(account: "agent", password: "test") { _ in } }
        #expect(!connection.isHeld)
    }
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { index in
            let start = hex.index(hex.startIndex, offsetBy: index)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}
