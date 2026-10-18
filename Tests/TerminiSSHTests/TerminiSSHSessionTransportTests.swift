import Foundation
import Testing
@testable import TerminiSSH

@MainActor
struct TerminiSSHSessionTransportTests {
    private func configuration(
        password: String = "secret",
        username: String = "user",
        host: String = "example"
    ) -> TerminiSSHConfiguration {
        TerminiSSHConfiguration(
            host: host,
            username: username,
            password: password,
            connectTimeout: .seconds(2)
        )
    }

    @Test func configurationDefaults() {
        let config = configuration()
        #expect(config.hostKeyAlias == nil)
        #expect(config.connectTimeout == .seconds(2))
        #expect(TerminiSSHConfiguration(host: "h", username: "u").connectTimeout == .seconds(10))
    }

    @Test func missingCredentialsFailAndCloseTheUnusedStream() async throws {
        let session = TerminiSSHSession()
        let stream = ScriptedByteStream()
        await session.connect(configuration: configuration(password: ""), transport: .stream(stream))
        #expect(session.status == .failed("Missing SSH credentials."))
        #expect(session.failure == .authenticationFailed)
        #expect(await closed(stream))
    }

    @Test func missingHostOrUsernameFailsAndClosesTheStream() async throws {
        let session = TerminiSSHSession()
        let stream = ScriptedByteStream()
        await session.connect(configuration: configuration(username: "  "), transport: .stream(stream))
        #expect(session.status == .failed("Missing SSH host or username."))
        #expect(await closed(stream))
    }

    @Test func invalidPrivateKeyFailsAndClosesTheStream() async throws {
        let session = TerminiSSHSession()
        let stream = ScriptedByteStream()
        var config = configuration(password: "")
        config.privateKeyPEM = "not a key"
        await session.connect(configuration: config, transport: .stream(stream))
        guard case .failed(let message) = session.status else {
            Issue.record("expected failure")
            return
        }
        #expect(message.hasPrefix("Invalid SSH private key"))
        #expect(session.failure == .authenticationFailed)
        #expect(await closed(stream))
    }

    @Test func aWhitespacePasswordIsUsedAsGiven() async throws {
        let session = TerminiSSHSession()
        let stream = ScriptedByteStream()
        stream.serverFinishes()
        await session.connect(configuration: configuration(password: "   "), transport: .stream(stream))
        // A password of spaces is a credential, so the attempt proceeds to the transport instead of stopping at
        // the credentials check.
        #expect(session.status != .failed("Missing SSH credentials."))
        await session.disconnect()
    }

    @Test func aStreamThatEndsBeforeAuthenticationIsUnreachable() async throws {
        let session = TerminiSSHSession()
        let stream = ScriptedByteStream()
        stream.serverFinishes()
        await session.connect(configuration: configuration(), transport: .stream(stream))
        #expect(await eventuallyMain { session.failure != nil })
        #expect(session.failure == .unreachable)
        guard case .failed = session.status else {
            Issue.record("expected failed status, got \(session.status)")
            return
        }
        await session.disconnect()
        #expect(stream.closes >= 1)
    }

    @Test func statusLinesCanBeSilenced() async throws {
        let session = TerminiSSHSession()
        session.showsStatusLines = false
        var output = Data()
        session.onRawOutput = { output.append($0) }
        let stream = ScriptedByteStream()
        stream.serverFinishes()
        await session.connect(configuration: configuration(), transport: .stream(stream))
        _ = await eventuallyMain { session.failure != nil }
        #expect(output.isEmpty)
        await session.disconnect()
    }

    @Test func statusLinesGoToTheRawSinkByDefault() async throws {
        let session = TerminiSSHSession()
        var output = Data()
        session.onRawOutput = { output.append($0) }
        let stream = ScriptedByteStream()
        stream.serverFinishes()
        await session.connect(configuration: configuration(), transport: .stream(stream))
        #expect(String(decoding: output, as: UTF8.self).contains("[Termini] Connecting to"))
        await session.disconnect()
    }

    @Test func tcpToAClosedPortFailsAsRefused() async throws {
        let session = TerminiSSHSession()
        var config = configuration(host: "127.0.0.1")
        config.port = try freePortNumber()
        await session.connect(configuration: config)
        #expect(session.failure == .refused)
        await session.disconnect()
    }

    private func closed(_ stream: ScriptedByteStream) async -> Bool {
        await eventuallyMain { stream.closes >= 1 }
    }

    private func eventuallyMain(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func freePortNumber() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
