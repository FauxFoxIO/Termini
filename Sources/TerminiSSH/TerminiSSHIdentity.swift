import CryptoKit
import Foundation
@preconcurrency import NIOSSH

/// A client key that signs SSH public-key authentication, held by the caller rather than pasted as text.
///
/// A Secure Enclave key never leaves the device's Secure Enclave: Termini only asks it to sign. Its public half, in
/// OpenSSH form, is what a server's `authorized_keys` lists.
public struct TerminiSSHIdentity: Sendable, Equatable {
    let privateKey: NIOSSHPrivateKey

    /// Two identities are equal when they hold the same key pair, which their public halves decide.
    public static func == (lhs: TerminiSSHIdentity, rhs: TerminiSSHIdentity) -> Bool {
        lhs.privateKey.publicKey == rhs.privateKey.publicKey
    }

    #if canImport(Darwin)
    /// A P-256 key in the Secure Enclave.
    public init(secureEnclaveKey: SecureEnclave.P256.Signing.PrivateKey) {
        privateKey = NIOSSHPrivateKey(secureEnclaveP256Key: secureEnclaveKey)
    }
    #endif

    /// A software P-256 key, for devices without a Secure Enclave.
    public init(p256Key: P256.Signing.PrivateKey) {
        privateKey = NIOSSHPrivateKey(p256Key: p256Key)
    }

    /// A software Ed25519 key.
    public init(ed25519Key: Curve25519.Signing.PrivateKey) {
        privateKey = NIOSSHPrivateKey(ed25519Key: ed25519Key)
    }

    /// The public key as one `authorized_keys` entry body: `<algorithm> <base64>`, followed by `comment` when given.
    /// A comment may not contain line breaks, which would start another entry.
    public func openSSHPublicKey(comment: String? = nil) -> String {
        let key = String(openSSHPublicKey: privateKey.publicKey)
        guard let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty else {
            return key
        }
        let singleLine = comment.unicodeScalars
            .filter { !CharacterSet.newlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
        return key + " " + String(String.UnicodeScalarView(singleLine))
    }

    /// The `SHA256:` fingerprint `ssh-keygen -l` prints for this key.
    public var fingerprint: String {
        (try? TerminiKnownHostKey(hostKey: privateKey.publicKey).fingerprint) ?? ""
    }
}

extension TerminiSSHIdentity {
    /// Whether `line` is a well-formed OpenSSH public key of a type Termini can verify, such as a host key a server's
    /// owner published or a key read from `authorized_keys`.
    public static func isValidOpenSSHPublicKey(_ line: String) -> Bool {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return false }
        return (try? NIOSSHPublicKey(openSSHPublicKey: fields[0] + " " + fields[1])) != nil
    }

    /// The `SHA256:` fingerprint of an OpenSSH public key line, or nil when it doesn't parse.
    public static func fingerprint(ofOpenSSHPublicKey line: String) -> String? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2,
              let key = try? NIOSSHPublicKey(openSSHPublicKey: fields[0] + " " + fields[1]) else { return nil }
        return try? TerminiKnownHostKey(hostKey: key).fingerprint
    }
}
