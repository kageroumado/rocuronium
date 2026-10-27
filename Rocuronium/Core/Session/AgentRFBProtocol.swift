import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security

nonisolated struct AgentRFBError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Bounded Apple RFB 3.889 messages for selecting a separate login session.
nonisolated enum AgentRFBProtocol {
    static let banner = Data("RFB 003.889\n".utf8)
    static let credentialFieldSize = 64
    static let maximumNameSize = 1024
    static let maximumSelectionSize = 4096

    static func integer(_ data: Data, at offset: Int, bytes: Int) throws -> UInt32 {
        guard offset >= 0, bytes > 0, bytes <= 4, offset + bytes <= data.count else {
            throw AgentRFBError("Screen Sharing sent a truncated message")
        }
        return data.dropFirst(offset).prefix(bytes).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func credentials(account: String, password: String) throws -> Data {
        let user = Array(account.utf8), secret = Array(password.utf8)
        guard !user.isEmpty, !secret.isEmpty,
              user.count < credentialFieldSize, secret.count < credentialFieldSize,
              !user.contains(0), !secret.contains(0) else {
            throw AgentRFBError("Screen Sharing requires a username and password of 1–63 UTF-8 bytes each")
        }
        var block = Data(count: credentialFieldSize * 2)
        let status = block.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw AgentRFBError("Credential padding failed (\(status))") }
        block.replaceSubrange(0...user.count, with: user + [0])
        block.replaceSubrange(credentialFieldSize...(credentialFieldSize + secret.count), with: secret + [0])
        return block
    }

    static func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, !plaintext.isEmpty, plaintext.count % kCCBlockSizeAES128 == 0 else {
            throw AgentRFBError("Invalid Screen Sharing credential block")
        }
        var output = Data(count: plaintext.count)
        var written = 0
        let status = output.withUnsafeMutableBytes { destination in
            key.withUnsafeBytes { keyBytes in
                plaintext.withUnsafeBytes { source in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, key.count, nil, source.baseAddress, plaintext.count,
                            destination.baseAddress, destination.count, &written)
                }
            }
        }
        guard status == kCCSuccess, written == plaintext.count else {
            throw AgentRFBError("Screen Sharing credential encryption failed (\(status))")
        }
        return output
    }

    /// ServerInit flags that matter to session selection.
    struct ServerFlags: OptionSet, Sendable {
        let rawValue: UInt32
        /// A SessionInfo block follows the name.
        static let sessionSelection = ServerFlags(rawValue: 0x04)
        /// screensharingd cannot capture the console's screen (`screenCapture flag` 0 in its
        /// `SendServerInitialiation`). Expected while another user owns the console; the
        /// virtual session is captured by its own agent, so selection still decides.
        static let screenCaptureDenied = ServerFlags(rawValue: 0x08)
    }

    /// Apple prepends 22 bytes of capabilities to ServerInit's name field.
    @discardableResult
    static func validateServerName(_ name: Data) throws -> ServerFlags {
        guard name.count >= 22, try integer(name, at: 0, bytes: 2) == 0 else {
            throw AgentRFBError("Screen Sharing did not offer enhanced session selection")
        }
        let flags = ServerFlags(rawValue: try integer(name, at: 2, bytes: 4))
        guard flags.contains(.sessionSelection) else {
            throw AgentRFBError("Screen Sharing did not offer a separate login session (flags \(flags.rawValue))")
        }
        return flags
    }

    static func validateSelectionInfo(_ body: Data) throws {
        guard body.count >= 74, body.count <= maximumSelectionSize else {
            throw AgentRFBError("Unsupported Screen Sharing session-info size (\(body.count))")
        }
        let version = try integer(body, at: 0, bytes: 2)
        let commands = try integer(body, at: 2, bytes: 4)
        guard version == 1, commands & 4 != 0 else {
            throw AgentRFBError("Screen Sharing does not permit connecting to a virtual session (version \(version), commands \(commands))")
        }
    }

    /// Version 2 carries encrypted credentials; command 2 selects the virtual session.
    static func selectVirtualSession(encryptedCredentials: Data) throws -> Data {
        guard encryptedCredentials.count == 128 else { throw AgentRFBError("Invalid encrypted credential size") }
        var message = Data(repeating: 0, count: 74)
        message[1] = 200
        message[3] = 2
        message[8] = 2
        let name = Data("Rocuronium".utf8)
        message.replaceSubrange(10..<(10 + name.count), with: name)
        message.append(encryptedCredentials)
        return message
    }

    static func validateSelectionResult(_ body: Data) throws {
        guard body.count >= 80, body.count <= maximumSelectionSize,
              try integer(body, at: 0, bytes: 2) == 1 else {
            throw AgentRFBError("Screen Sharing sent an unsupported session-selection result (size \(body.count))")
        }
        guard body[2] == 0 else {
            throw AgentRFBError("Screen Sharing refused the virtual session (result \(body[2]))")
        }
        // Successful selection leaves the optional follow-up SessionInfo zero-filled.
        if body.dropFirst(4).contains(where: { $0 != 0 }) {
            guard try integer(body, at: 4, bytes: 2) == 74,
                  try integer(body, at: 6, bytes: 2) == 1 else {
                throw AgentRFBError("Screen Sharing sent unsupported follow-up session information")
            }
        }
    }
}

/// Security.framework owns the private exponent; wire values use fixed-width big-endian encoding.
nonisolated final class AgentRFBDiffieHellman {
    private typealias Create = @convention(c) (UInt32, UnsafePointer<UInt8>, Int, UInt32, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<OpaquePointer?>) -> OSStatus
    private typealias Generate = @convention(c) (OpaquePointer, UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<Int>) -> OSStatus
    private typealias Compute = @convention(c) (OpaquePointer, UnsafePointer<UInt8>, Int, UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<Int>) -> OSStatus
    private typealias Destroy = @convention(c) (OpaquePointer) -> Void
    private let library: UnsafeMutableRawPointer
    private let context: OpaquePointer
    private let compute: Compute
    private let destroy: Destroy
    let publicKey: Data
    let size: Int

    init(generator: UInt32, prime: Data) throws {
        guard (64...1024).contains(prime.count), generator >= 2, prime.first != 0, prime.last.map({ $0 & 1 == 1 }) == true else {
            throw AgentRFBError("Screen Sharing sent unsupported Diffie–Hellman parameters")
        }
        guard let library = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW | RTLD_LOCAL) else {
            throw AgentRFBError("Security.framework could not be loaded")
        }
        guard let c = dlsym(library, "SecDHCreate"), let g = dlsym(library, "SecDHGenerateKeypair"),
              let k = dlsym(library, "SecDHComputeKey"), let d = dlsym(library, "SecDHDestroy") else {
            dlclose(library)
            throw AgentRFBError("This macOS version lacks the required Diffie–Hellman functions")
        }
        let create = unsafeBitCast(c, to: Create.self)
        let generate = unsafeBitCast(g, to: Generate.self)
        let destroy = unsafeBitCast(d, to: Destroy.self)
        var context: OpaquePointer?
        let status = prime.withUnsafeBytes {
            create(generator, $0.bindMemory(to: UInt8.self).baseAddress!, prime.count, 0, nil, 0, &context)
        }
        guard status == errSecSuccess, let context else {
            dlclose(library)
            throw AgentRFBError("Diffie–Hellman setup failed (\(status))")
        }
        var publicKey = [UInt8](repeating: 0, count: prime.count)
        var length = publicKey.count
        let generated = generate(context, &publicKey, &length)
        guard generated == errSecSuccess, length > 0, length <= prime.count else {
            destroy(context)
            dlclose(library)
            throw AgentRFBError("Diffie–Hellman key generation failed (\(generated))")
        }
        self.library = library
        self.context = context
        self.compute = unsafeBitCast(k, to: Compute.self)
        self.destroy = destroy
        self.size = prime.count
        self.publicKey = Data(repeating: 0, count: prime.count - length) + Data(publicKey.prefix(length))
    }

    func encryptionKey(peer: Data) throws -> Data {
        guard peer.count == size else { throw AgentRFBError("Invalid Diffie–Hellman public-key size") }
        var secret = [UInt8](repeating: 0, count: size)
        defer { _ = secret.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        var length = secret.count
        let status = peer.withUnsafeBytes {
            compute(context, $0.bindMemory(to: UInt8.self).baseAddress!, peer.count, &secret, &length)
        }
        guard status == errSecSuccess, length > 0, length <= size else {
            throw AgentRFBError("Diffie–Hellman key agreement failed (\(status))")
        }
        var padded = Data(repeating: 0, count: size - length) + Data(secret.prefix(length))
        defer { padded.resetBytes(in: 0..<padded.count) }
        return Data(Insecure.MD5.hash(data: padded))
    }

    deinit {
        destroy(context)
        dlclose(library)
    }
}
