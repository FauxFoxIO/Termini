import CryptoKit
import Foundation
import Testing
@testable import TerminiSSH

@MainActor
struct TerminiSSHIdentityTests {
    @Test func p256PublicKeyIsAnECDSALine() {
        let identity = TerminiSSHIdentity(p256Key: P256.Signing.PrivateKey())
        let line = identity.openSSHPublicKey()
        #expect(line.hasPrefix("ecdsa-sha2-nistp256 "))
        #expect(line.split(separator: " ").count == 2)
        #expect(TerminiSSHIdentity.isValidOpenSSHPublicKey(line))
    }

    @Test func ed25519PublicKeyIsAnEd25519Line() {
        let identity = TerminiSSHIdentity(ed25519Key: Curve25519.Signing.PrivateKey())
        let line = identity.openSSHPublicKey()
        #expect(line.hasPrefix("ssh-ed25519 "))
        #expect(TerminiSSHIdentity.isValidOpenSSHPublicKey(line))
    }

    @Test func commentIsAppendedAndCollapsedToOneLine() {
        let identity = TerminiSSHIdentity(ed25519Key: Curve25519.Signing.PrivateKey())
        let plain = identity.openSSHPublicKey()
        #expect(identity.openSSHPublicKey(comment: "mirage device") == plain + " mirage device")
        let multi = identity.openSSHPublicKey(comment: "a\nb\r\nc")
        #expect(!multi.contains("\n"))
        #expect(!multi.contains("\r"))
        #expect(multi.hasPrefix(plain + " "))
        #expect(identity.openSSHPublicKey(comment: "  \n ") == plain)
        #expect(identity.openSSHPublicKey(comment: nil) == plain)
    }

    @Test func equalityFollowsTheKeyPair() {
        let p256 = P256.Signing.PrivateKey()
        #expect(TerminiSSHIdentity(p256Key: p256) == TerminiSSHIdentity(p256Key: p256))
        #expect(TerminiSSHIdentity(p256Key: p256) != TerminiSSHIdentity(p256Key: P256.Signing.PrivateKey()))
        let ed = Curve25519.Signing.PrivateKey()
        #expect(TerminiSSHIdentity(ed25519Key: ed) == TerminiSSHIdentity(ed25519Key: ed))
    }

    @Test func fingerprintMatchesTheFingerprintOfItsPublicLine() throws {
        let identity = TerminiSSHIdentity(p256Key: P256.Signing.PrivateKey())
        #expect(identity.fingerprint.hasPrefix("SHA256:"))
        let line = identity.openSSHPublicKey(comment: "x")
        #expect(TerminiSSHIdentity.fingerprint(ofOpenSSHPublicKey: line) == identity.fingerprint)
    }

    @Test func malformedPublicKeyLinesAreRejected() {
        #expect(!TerminiSSHIdentity.isValidOpenSSHPublicKey(""))
        #expect(!TerminiSSHIdentity.isValidOpenSSHPublicKey("ssh-ed25519"))
        #expect(!TerminiSSHIdentity.isValidOpenSSHPublicKey("ssh-ed25519 not-base64!!"))
        #expect(!TerminiSSHIdentity.isValidOpenSSHPublicKey("unknown-type AAAA"))
        #expect(TerminiSSHIdentity.fingerprint(ofOpenSSHPublicKey: "garbage") == nil)
    }

    @Test func identityIsStoredOnTheConfiguration() {
        let identity = TerminiSSHIdentity(ed25519Key: Curve25519.Signing.PrivateKey())
        let config = TerminiSSHConfiguration(host: "h", username: "u", identity: identity)
        #expect(config.identity == identity)
        #expect(TerminiSSHConfiguration(host: "h", username: "u").identity == nil)
    }

    @Test func anIdentityAloneCountsAsACredential() async throws {
        let session = TerminiSSHSession()
        let stream = ScriptedByteStream()
        stream.serverFinishes()
        let config = TerminiSSHConfiguration(
            host: "example",
            username: "user",
            identity: TerminiSSHIdentity(ed25519Key: Curve25519.Signing.PrivateKey()),
            connectTimeout: .seconds(2)
        )
        await session.connect(configuration: config, transport: .stream(stream))
        #expect(session.status != .failed("Missing SSH credentials."))
        await session.disconnect()
    }

    @Test func failureCasesAreDistinct() {
        let all: [TerminiSSHFailure] = [.authenticationFailed, .passwordRequired, .closedAfterAuthentication, .disconnected]
        #expect(Set(all.map { "\($0)" }).count == all.count)
    }
}
