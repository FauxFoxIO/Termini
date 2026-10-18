import Foundation
import Network
import NIOCore
import NIOPosix
import Testing
@testable import TerminiSSH

/// A scripted byte stream standing in for a tunnel.
final class ScriptedByteStream: TerminiSSHByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data] = []
    private var finished = false
    private var waiter: CheckedContinuation<Data?, Never>?
    private var sentData = Data()
    private var closeCount = 0

    var sent: Data { lock.withLock { sentData } }
    var closes: Int { lock.withLock { closeCount } }

    func serverSends(_ data: Data) {
        let waiter: CheckedContinuation<Data?, Never>? = lock.withLock {
            if let waiter = self.waiter {
                self.waiter = nil
                return waiter
            }
            queue.append(data)
            return nil
        }
        waiter?.resume(returning: data)
    }

    func serverFinishes() {
        let waiter: CheckedContinuation<Data?, Never>? = lock.withLock {
            finished = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: nil)
    }

    func receive() async throws -> Data? {
        await withCheckedContinuation { continuation in
            let immediate: Data?? = lock.withLock {
                if !queue.isEmpty { return .some(queue.removeFirst()) }
                if finished { return .some(nil) }
                waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func send(_ data: Data) async throws {
        lock.withLock { sentData.append(data) }
    }

    func close() async {
        lock.withLock { closeCount += 1 }
        serverFinishes()
    }
}

private final class Recorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NSLock()
    private var bytes = Data()
    private var closed = false

    var received: Data { lock.withLock { bytes } }
    var isInactive: Bool { lock.withLock { closed } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        lock.withLock { bytes.append(contentsOf: buffer.readableBytesView) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.withLock { closed = true }
    }
}

private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

struct TerminiSSHTransportTests {
    @Test func streamTransportCarriesBytesBothWays() async throws {
        let stream = ScriptedByteStream()
        let recorder = Recorder()
        let connection = try await TerminiSSHTransportConnector.connect(
            transport: .stream(stream),
            host: "example",
            port: 22,
            connectTimeout: .seconds(1)
        ) { channel in
            channel.pipeline.addHandler(recorder)
        }

        stream.serverSends(Data("SSH-2.0-test\r\n".utf8))
        #expect(await eventually { recorder.received == Data("SSH-2.0-test\r\n".utf8) })

        var buffer = connection.channel.allocator.buffer(capacity: 8)
        buffer.writeString("hello")
        try await connection.channel.writeAndFlush(buffer).get()
        #expect(await eventually { stream.sent == Data("hello".utf8) })

        await connection.close()
        #expect(stream.closes >= 1)
    }

    @Test func serverFinishingClosesTheChannel() async throws {
        let stream = ScriptedByteStream()
        let recorder = Recorder()
        let connection = try await TerminiSSHTransportConnector.connect(
            transport: .stream(stream),
            host: "example",
            port: 22,
            connectTimeout: .seconds(1)
        ) { channel in
            channel.pipeline.addHandler(recorder)
        }
        stream.serverSends(Data("bye".utf8))
        stream.serverFinishes()
        #expect(await eventually { recorder.received == Data("bye".utf8) })
        #expect(await eventually { recorder.isInactive })
        await connection.close()
        #expect(stream.closes >= 1)
    }

    @Test func tcpTransportToAClosedPortIsRefused() async throws {
        let port = try closedLoopbackPort()
        do {
            _ = try await TerminiSSHTransportConnector.connect(
                transport: .tcp,
                host: "127.0.0.1",
                port: port,
                connectTimeout: .seconds(2)
            ) { channel in channel.eventLoop.makeSucceededFuture(()) }
            Issue.record("connecting to a closed port should fail")
        } catch {
            #expect(TerminiSSHTransportConnector.isConnectionRefused(error))
        }
    }

    @Test func recognizesRefusalAcrossErrorTypes() {
        #expect(TerminiSSHTransportConnector.isConnectionRefused(NWError.posix(.ECONNREFUSED)))
        #expect(!TerminiSSHTransportConnector.isConnectionRefused(NWError.posix(.ETIMEDOUT)))
        #expect(TerminiSSHTransportConnector.isConnectionRefused(IOError(errnoCode: ECONNREFUSED, reason: "connect")))
        #expect(!TerminiSSHTransportConnector.isConnectionRefused(IOError(errnoCode: ETIMEDOUT, reason: "connect")))
        #expect(!TerminiSSHTransportConnector.isConnectionRefused(CancellationError()))
    }

    @Test func socketPairErrorDescribesTheCause() {
        let error = TerminiSSHTransportConnector.ConnectorError.socketPairUnavailable(EMFILE)
        #expect(error.errorDescription?.contains("SSH tunnel") == true)
    }
}

private func closedLoopbackPort() throws -> Int {
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
