import Foundation
import Network
import NIOCore
import NIOPosix
import NIOTransportServices
import Darwin

/// A duplex byte stream that carries one SSH connection, such as a tunnel through another network.
///
/// Termini reads server bytes with ``receive()`` until it returns `nil`, writes client bytes with ``send(_:)``, and
/// calls ``close()`` once when the session ends. A pending ``receive()`` should end when its task is cancelled.
public protocol TerminiSSHByteStream: AnyObject, Sendable {
    /// Returns the next bytes from the server, or `nil` once the server has finished sending.
    func receive() async throws -> Data?
    /// Sends client bytes to the server.
    func send(_ data: Data) async throws
    /// Ends the stream in both directions.
    func close() async
}

/// How a session reaches the SSH server.
public enum TerminiSSHTransport: Sendable {
    /// A TCP connection to the configuration's host and port.
    case tcp
    /// An established byte stream. The configuration's host and port then only name the server in status text and,
    /// without a host-key alias, in host-key verification.
    case stream(any TerminiSSHByteStream)
}

/// Why a session's last connection attempt failed.
public enum TerminiSSHFailure: Equatable, Sendable {
    /// The transport couldn't reach the server, or closed before the SSH session was authenticated.
    case unreachable
    /// The server's address actively refused the connection.
    case refused
    /// The server's host key didn't match the trusted key or the pinned fingerprint.
    case hostKeyRejected
    /// The server rejected every offered credential.
    case authenticationFailed
    /// The connection failed after authentication.
    case disconnected
}

/// One open transport carrying the SSH connection's channel, and what tearing it down takes.
struct TerminiSSHTransportConnection {
    let channel: Channel
    private let group: NIOTSEventLoopGroup?
    private let pumpTask: Task<Void, Never>?
    private let stream: (any TerminiSSHByteStream)?

    init(
        channel: Channel,
        group: NIOTSEventLoopGroup? = nil,
        pumpTask: Task<Void, Never>? = nil,
        stream: (any TerminiSSHByteStream)? = nil
    ) {
        self.channel = channel
        self.group = group
        self.pumpTask = pumpTask
        self.stream = stream
    }

    func close() async {
        try? await channel.close().get()
        pumpTask?.cancel()
        if let stream {
            await stream.close()
        }
        if let group {
            try? await group.shutdownGracefully()
        }
    }

    /// Starts the teardown without waiting, for deinitialization.
    func closeWithoutWaiting() {
        channel.close(promise: nil)
        pumpTask?.cancel()
        if let stream {
            Task { await stream.close() }
        }
        group?.shutdownGracefully(queue: .global()) { _ in }
    }
}

enum TerminiSSHTransportConnector {
    enum ConnectorError: LocalizedError {
        case socketPairUnavailable(Int32)

        var errorDescription: String? {
            switch self {
            case .socketPairUnavailable(let code):
                return "The SSH tunnel couldn't start (\(String(cString: strerror(code))))."
            }
        }
    }

    static func connect(
        transport: TerminiSSHTransport,
        host: String,
        port: Int,
        connectTimeout: Duration,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> TerminiSSHTransportConnection {
        switch transport {
        case .tcp:
            return try await connectTCP(
                host: host,
                port: port,
                connectTimeout: connectTimeout,
                channelInitializer: channelInitializer
            )
        case .stream(let stream):
            return try await connectStream(stream, channelInitializer: channelInitializer)
        }
    }

    private static func connectTCP(
        host: String,
        port: Int,
        connectTimeout: Duration,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> TerminiSSHTransportConnection {
        let group = NIOTSEventLoopGroup()
        do {
            // Without this, Network.framework parks a refused connection as "waiting" until the timeout, so the
            // refusal would never reach the caller as ``TerminiSSHFailure/refused``.
            let channel = try await NIOTSConnectionBootstrap(group: group)
                .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
                .connectTimeout(timeAmount(connectTimeout))
                .channelInitializer(channelInitializer)
                .connect(host: host, port: port)
                .get()
            return TerminiSSHTransportConnection(channel: channel, group: group)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// NIO channels need a socket, so a connected socket pair joins the SSH channel to a pump that copies bytes
    /// between the pair's other end and the stream. Nothing outside this process can reach the pair.
    private static func connectStream(
        _ stream: any TerminiSSHByteStream,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> TerminiSSHTransportConnection {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            let code = errno
            await stream.close()
            throw ConnectorError.socketPairUnavailable(code)
        }
        var enabled: Int32 = 1
        for descriptor in descriptors {
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        }

        let group = MultiThreadedEventLoopGroup.singleton
        let pump: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        do {
            pump = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .withConnectedSocket(descriptors[1]) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                            wrappingChannelSynchronously: channel,
                            configuration: .init(isOutboundHalfClosureEnabled: true)
                        )
                    }
                }
        } catch {
            // NIO may already own the pump descriptor, so only the untouched SSH end is closed here.
            _ = Darwin.close(descriptors[0])
            await stream.close()
            throw error
        }

        let sshChannel: Channel
        do {
            sshChannel = try await ClientBootstrap(group: group)
                .channelInitializer(channelInitializer)
                .withConnectedSocket(descriptors[0])
                .get()
        } catch {
            try? await pump.channel.close().get()
            await stream.close()
            throw error
        }

        let pumpTask = Task {
            try? await pump.executeThenClose { inbound, outbound in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await buffer in inbound {
                            try await stream.send(Data(buffer.readableBytesView))
                        }
                    }
                    group.addTask {
                        while let data = try await stream.receive() {
                            guard !data.isEmpty else { continue }
                            try await outbound.write(ByteBuffer(bytes: data))
                        }
                        outbound.finish()
                    }
                    // Either direction ending ends the connection. Bytes already written to the pair stay readable
                    // by the SSH channel after the pump closes its end.
                    defer { group.cancelAll() }
                    try await group.next()
                }
            }
            await stream.close()
        }

        return TerminiSSHTransportConnection(channel: sshChannel, pumpTask: pumpTask, stream: stream)
    }

    static func isConnectionRefused(_ error: Error) -> Bool {
        if let networkError = error as? NWError, case .posix(let code) = networkError {
            return code == .ECONNREFUSED
        }
        if let ioError = error as? IOError {
            return ioError.errnoCode == ECONNREFUSED
        }
        if let connectionError = error as? NIOConnectionError {
            return connectionError.connectionErrors.contains { isConnectionRefused($0.error) }
        }
        return false
    }

    private static func timeAmount(_ duration: Duration) -> TimeAmount {
        let components = duration.components
        return .nanoseconds(components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000)
    }
}
