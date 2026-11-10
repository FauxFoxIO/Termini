import Termini
import CryptoKit
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import NIOTransportServices

public struct TerminiSSHConfiguration: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var privateKeyPEM: String?
    /// A key the caller holds, such as one in the Secure Enclave, offered for public-key authentication ahead of
    /// `privateKeyPEM` and the password.
    public var identity: TerminiSSHIdentity?
    public var term: String
    public var startupCommand: String?
    // Run `startupCommand` as an SSH *exec* request
    // instead of typing it into an interactive shell after a delay. Exec gives
    // a clean byte stream (no shell echo/prompt/rc noise — required for
    // protocol channels like `tmux -C`) and a real exit status when the
    // command dies. Default false so existing shell-typed call sites keep
    // their behavior.
    public var useExecRequest: Bool
    /// Whether the channel asks the server for a pseudo-terminal. An exec channel that carries a binary protocol
    /// turns it off: without a PTY the server translates no line endings, echoes nothing and keeps stderr out of
    /// the output, which then holds only the command's stdout.
    public var requestsPseudoTerminal: Bool
    public var hostKeyPolicy: TerminiSSHHostKeyPolicy
    public var hostKeyFingerprint: String?
    /// The name host-key verification uses instead of `host`, so one server reached at several addresses or through
    /// a tunnel keeps one trusted key.
    public var hostKeyAlias: String?
    /// How long a TCP transport waits for the server to accept the connection.
    public var connectTimeout: Duration

    public init(
        host: String,
        port: Int = 22,
        username: String,
        password: String = "",
        privateKeyPEM: String? = nil,
        identity: TerminiSSHIdentity? = nil,
        term: String = "xterm-256color",
        startupCommand: String? = nil,
        useExecRequest: Bool = false,
        requestsPseudoTerminal: Bool = true,
        hostKeyPolicy: TerminiSSHHostKeyPolicy = .trustOnFirstUse,
        hostKeyFingerprint: String? = nil,
        hostKeyAlias: String? = nil,
        connectTimeout: Duration = .seconds(10)
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.privateKeyPEM = privateKeyPEM
        self.identity = identity
        self.term = term
        self.startupCommand = startupCommand
        self.useExecRequest = useExecRequest
        self.requestsPseudoTerminal = requestsPseudoTerminal
        self.hostKeyPolicy = hostKeyPolicy
        self.hostKeyFingerprint = hostKeyFingerprint
        self.hostKeyAlias = hostKeyAlias
        self.connectTimeout = connectTimeout
    }
}

@MainActor
public final class TerminiSSHSession {
    public enum Status: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    /// The session's phase, which owns the transport and channels of the attempt it belongs to. `onStatusChange`
    /// fires only when the public status it maps to changes.
    private var phase: Phase = .disconnected {
        didSet {
            let next = Status(phase)
            if next != Status(oldValue) { onStatusChange?(next) }
        }
    }

    private var nextAttemptID: UInt64 = 0

    public var status: Status { Status(phase) }

    public private(set) var endpointLabel: String = ""
    /// Why the connection attempt failed; `nil` unless the status is `.failed`.
    public var failure: TerminiSSHFailure? {
        if case .failed(let failure) = phase { return failure.reason }
        return nil
    }
    /// Whether the server offered public-key authentication before the attempt failed; `nil` unless the status is
    /// `.failed` and the server said. A server that offers only passwords, such as a Mac's startup screen while
    /// FileVault is locked, can't take a key.
    public var serverOffersPublicKeys: Bool? {
        if case .failed(let failure) = phase { return failure.serverOffersPublicKeys }
        return nil
    }
    /// Whether `[Termini]` connection status lines go to the output.
    public var showsStatusLines = true
    public var onStatusChange: ((Status) -> Void)? {
        didSet { onStatusChange?(status) }
    }

    private let controller: TerminiTerminalController?
    private var terminalColumns = 120
    private var terminalRows = 34
    private var terminalPixelWidth = 0
    private var terminalPixelHeight = 0

    // MARK: Raw output sink.
    // When set, remote bytes (and [Termini] status lines) bypass the terminal
    // controller and go straight to this closure. Lets a protocol client (e.g.
    // a `tmux -C` control channel) reuse the whole SSH session machinery
    // without pretending to be a rendered terminal.
    public var onRawOutput: ((Data) -> Void)?

    public init(controller: TerminiTerminalController) {
        self.controller = controller
        controller.onInputText = { [weak self] text in
            self?.send(self?.normalizeInput(text) ?? text)
        }
        controller.onDeleteBackward = { [weak self] in
            self?.send("\u{7F}")
        }
        controller.onTransportWrite = { [weak self] data in
            self?.send(data)
        }
    }

    /// Creates a session with no terminal controller. Remote output and status lines go only to ``onRawOutput``,
    /// and input goes through ``send(_:)``.
    public init() {
        controller = nil
    }

    deinit {
        phase.owned.closeWithoutWaiting()
    }

    /// Connects over `transport`, TCP to the configuration's host and port by default.
    ///
    /// A second call replaces the attempt in flight or the open connection: what the earlier one opened is closed,
    /// and its late events are ignored. Returns once the session channel is open or the attempt has failed.
    public func connect(configuration: TerminiSSHConfiguration, transport: TerminiSSHTransport = .tcp) async {
        nextAttemptID += 1
        let id = nextAttemptID

        let host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        // Spaces are valid password characters, so the password is used exactly as given.
        let password = configuration.password
        let privateKeyPEM = configuration.privateKeyPEM?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startupCommand = configuration.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostKeyFingerprint = configuration.hostKeyFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostKeyAlias = configuration.hostKeyAlias?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty, !username.isEmpty else {
            await reject("Missing SSH host or username.", transport: transport)
            return
        }

        guard !password.isEmpty || !(privateKeyPEM ?? "").isEmpty || configuration.identity != nil else {
            await reject("Missing SSH credentials.", transport: transport)
            return
        }

        let parsedPrivateKey: NIOSSHPrivateKey?
        do {
            if let identity = configuration.identity {
                parsedPrivateKey = identity.privateKey
            } else if let privateKeyPEM, !privateKeyPEM.isEmpty {
                parsedPrivateKey = try Self.parsePrivateKey(privateKeyPEM)
            } else {
                parsedPrivateKey = nil
            }
        } catch {
            await reject("Invalid SSH private key: \(error.localizedDescription)", transport: transport)
            return
        }

        // In exec mode the command runs as the channel's exec request; only shell mode types it into the remote shell.
        let useExec = configuration.useExecRequest && !(startupCommand ?? "").isEmpty
        let authDelegate = ClientAuthenticationDelegate(
            username: username,
            password: password.isEmpty ? nil : password,
            privateKey: parsedPrivateKey
        )
        let attempt = Attempt(
            id: id,
            authentication: authDelegate,
            typedStartupCommand: useExec || (startupCommand ?? "").isEmpty ? nil : startupCommand
        )

        endpointLabel = "\(username)@\(host):\(configuration.port)"
        let replaced = replacePhase(with: .connecting(attempt, .opening(authenticated: false)))
        resetTerminalSurface()
        appendStatusLine("[Termini] Connecting to \(endpointLabel)")
        await replaced.close()
        guard isCurrent(id) else {
            closeUnusedTransport(transport)
            return
        }

        let hostKeyValidator = HostKeyValidator(
            host: (hostKeyAlias?.isEmpty == false ? hostKeyAlias : nil) ?? host,
            port: configuration.port,
            policy: configuration.hostKeyPolicy,
            pinnedFingerprint: hostKeyFingerprint,
            onNote: { [weak self] (note: String) in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(id) else { return }
                    self.appendStatusLine("[Termini] \(note)")
                }
            }
        )
        let initialColumns = terminalColumns
        let initialRows = terminalRows
        let initialPixelWidth = terminalPixelWidth
        let initialPixelHeight = terminalPixelHeight

        let readyCallback: @Sendable (Channel) -> Void = { [weak self] channel in
            Task { @MainActor [weak self] in
                await self?.receive(.ready(channel), attempt: id).close()
            }
        }

        let outputCallback: @Sendable (Data) -> Void = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(id) else { return }
                self.emitOutput(data)
            }
        }

        let exitCallback: @Sendable (Int?) -> Void = { [weak self] code in
            Task { @MainActor [weak self] in
                await self?.receive(.remoteExited(code), attempt: id).close()
            }
        }

        let errorCallback: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.receive(.failed(error), attempt: id).close()
            }
        }

        let authenticatedCallback: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.receive(.authenticated, attempt: id).close()
            }
        }

        do {
            let channelInitializer: @Sendable (Channel) -> EventLoopFuture<Void> = { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .client(
                                .init(
                                    userAuthDelegate: authDelegate,
                                    serverAuthDelegate: hostKeyValidator
                                )
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        ConnectionErrorHandler(onError: errorCallback, onAuthenticated: authenticatedCallback)
                    )
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

            let transportConnection = try await TerminiSSHTransportConnector.connect(
                transport: transport,
                host: host,
                port: configuration.port,
                connectTimeout: configuration.connectTimeout,
                channelInitializer: channelInitializer
            )
            // A superseded attempt gets its transport back here and closes it.
            await receive(.transportOpened(transportConnection), attempt: id).close()
            guard isCurrent(id) else { return }
            let connectionChannel = transportConnection.channel

            let shellChannel = try await connectionChannel.pipeline
                .handler(type: NIOSSHHandler.self)
                .flatMap { sshHandler in
                    let promise = connectionChannel.eventLoop.makePromise(of: Channel.self)
                    sshHandler.createChannel(promise) { childChannel, channelType in
                        guard channelType == .session else {
                            return connectionChannel.eventLoop.makeFailedFuture(SessionError.invalidChannelType)
                        }

                        return childChannel.pipeline.addHandler(
                            ChannelHandler(
                                term: configuration.term,
                                execCommand: useExec ? startupCommand : nil,
                                requestsPseudoTerminal: configuration.requestsPseudoTerminal || !useExec,
                                initialColumns: initialColumns,
                                initialRows: initialRows,
                                initialPixelWidth: initialPixelWidth,
                                initialPixelHeight: initialPixelHeight,
                                onReady: readyCallback,
                                onOutput: outputCallback,
                                onExit: exitCallback,
                                onError: errorCallback
                            )
                        )
                    }

                    return promise.futureResult
                }
                .get()

            await receive(.shellOpened(shellChannel), attempt: id).close()
        } catch {
            await receive(.failed(error), attempt: id).close()
        }
    }

    /// Leaves a connecting or connected session for `.disconnected` and closes what it held. A failed session keeps
    /// its failure.
    public func disconnect() async {
        switch phase {
        case .connecting, .connected:
            await replacePhase(with: .disconnected).close()
        case .disconnected, .failed:
            return
        }
    }

    public func updateTerminalSize(_ size: TerminiTerminalSize) {
        resize(
            columns: size.columns,
            rows: size.rows,
            pixelWidth: size.columns * size.cellWidthPixels,
            pixelHeight: size.rows * size.cellHeightPixels
        )
    }

    public func send(_ text: String) {
        send(Data(text.utf8))
    }

    public func send(_ data: Data) {
        guard let shellChannel = phase.link?.shell else { return }
        guard !data.isEmpty else { return }
        var buffer = shellChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        shellChannel.writeAndFlush(buffer, promise: nil)
    }

    private func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        terminalColumns = max(columns, 2)
        terminalRows = max(rows, 1)
        terminalPixelWidth = max(pixelWidth, 0)
        terminalPixelHeight = max(pixelHeight, 0)

        guard let shellChannel = phase.link?.shell else { return }
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: terminalColumns,
            terminalRowHeight: terminalRows,
            terminalPixelWidth: terminalPixelWidth,
            terminalPixelHeight: terminalPixelHeight
        )
        shellChannel.triggerUserOutboundEvent(request, promise: nil)
    }

    private func isCurrent(_ id: UInt64) -> Bool {
        phase.attempt?.id == id
    }

    /// Leaves the current phase for `next` and returns what the old phase owned, which the caller closes.
    private func replacePhase(with next: Phase) -> Release {
        let released = phase.owned
        phase = next
        return released
    }

    /// Fails the session because the configuration can't start an attempt.
    private func reject(_ message: String, transport: TerminiSSHTransport) async {
        let replaced = replacePhase(
            with: .failed(Failure(reason: .authenticationFailed, message: message, serverOffersPublicKeys: nil))
        )
        closeUnusedTransport(transport)
        await replaced.close()
    }

    /// The single funnel for what happens to an attempt. An event from an attempt that is no longer current changes
    /// nothing and hands back the resources it carried; otherwise the phase moves and the result holds what the move
    /// gave up. The caller closes the result.
    private func receive(_ event: Event, attempt id: UInt64) -> Release {
        guard let attempt = phase.attempt, attempt.id == id else { return event.carried }

        switch event {
        case .transportOpened(let transport):
            guard case .connecting(_, .opening(let authenticated)) = phase else { return event.carried }
            phase = .connecting(attempt, .handshaking(transport, authenticated: authenticated))
            return Release()

        case .authenticated:
            switch phase {
            case .connecting(_, .opening):
                phase = .connecting(attempt, .opening(authenticated: true))
            case .connecting(_, .handshaking(let transport, _)):
                phase = .connecting(attempt, .handshaking(transport, authenticated: true))
            case .connecting(_, .startingSession), .connected, .disconnected, .failed:
                break
            }
            return Release()

        case .shellOpened(let shell):
            switch phase {
            case .connecting(_, .handshaking(let transport, _)):
                phase = .connecting(attempt, .startingSession(Link(transport: transport, shell: shell)))
                return Release()
            case .connecting(_, .opening):
                return event.carried
            case .connecting(_, .startingSession), .connected, .disconnected, .failed:
                // The shell's ready reply already carried this channel.
                return Release()
            }

        case .ready(let shell):
            switch phase {
            case .connecting(_, .handshaking(let transport, _)):
                enterConnected(attempt, link: Link(transport: transport, shell: shell))
                return Release()
            case .connecting(_, .startingSession(let link)):
                enterConnected(attempt, link: link)
                return Release()
            case .connecting(_, .opening):
                return event.carried
            case .connected, .disconnected, .failed:
                return Release()
            }

        case .remoteExited(let code):
            if let code {
                appendStatusLine("[Termini] Remote shell exited with status \(code)")
            } else {
                appendStatusLine("[Termini] Remote shell closed")
            }
            return replacePhase(with: .disconnected)

        case .failed(let error):
            let failure = Self.classify(error, in: phase, attempt: attempt)
            appendStatusLine("[Termini] SSH error: \(failure.message)")
            return replacePhase(with: .failed(failure))
        }
    }

    private func enterConnected(_ attempt: Attempt, link: Link) {
        phase = .connected(attempt, link)
        appendStatusLine("[Termini] Connected")

        guard let startupCommand = attempt.typedStartupCommand else { return }
        let id = attempt.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            // The command goes only to the shell of the attempt that asked for it.
            guard let self, self.isCurrent(id), case .connected = self.phase else { return }
            self.send("\(startupCommand)\r")
        }
    }

    private static func classify(_ error: Error, in phase: Phase, attempt: Attempt) -> Failure {
        let message = error.localizedDescription
        if error is TerminiSSHHostKeyValidationError {
            return Failure(reason: .hostKeyRejected, message: message, serverOffersPublicKeys: nil)
        }

        let authentication = attempt.authentication
        let serverOffersPublicKeys = authentication.offeredMethods.map { $0.contains(.publicKey) }
        let isAuthenticated: Bool
        let isSessionReady: Bool
        switch phase {
        case .connecting(_, let stage):
            isAuthenticated = stage.isAuthenticated
            isSessionReady = false
        case .connected:
            isAuthenticated = true
            isSessionReady = true
        case .disconnected, .failed:
            isAuthenticated = false
            isSessionReady = false
        }

        let reason: TerminiSSHFailure
        if authentication.hasExhaustedOffers, !isAuthenticated {
            reason = authentication.couldUsePassword ? .passwordRequired : .authenticationFailed
        } else if TerminiSSHTransportConnector.isConnectionRefused(error) {
            reason = .refused
        } else if !isAuthenticated {
            reason = .unreachable
        } else {
            reason = isSessionReady ? .disconnected : .closedAfterAuthentication
        }
        return Failure(reason: reason, message: message, serverOffersPublicKeys: serverOffersPublicKeys)
    }

    /// A stream that was handed over but never used still ends, so its tunnel doesn't linger.
    private func closeUnusedTransport(_ transport: TerminiSSHTransport) {
        guard case .stream(let stream) = transport else { return }
        Task { await stream.close() }
    }

    /// Single output funnel — raw sink when set, else the
    /// terminal controller.
    private func emitOutput(_ data: Data) {
        if let onRawOutput {
            onRawOutput(data)
        } else {
            controller?.processRemoteOutput(data)
        }
    }

    private func appendStatusLine(_ line: String) {
        guard showsStatusLines else { return }
        emitOutput(Data("\(line)\r\n".utf8))
    }

    private func resetTerminalSurface() {
        controller?.processRemoteOutput(Data("\u{001B}c".utf8))
    }

    private func normalizeInput(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
    }

    private static func parsePrivateKey(_ pemRepresentation: String) throws -> NIOSSHPrivateKey {
        let normalized = pemRepresentation.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.localizedCaseInsensitiveContains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSHPrivateKey(normalized)
        }

        if let key = try? P256.Signing.PrivateKey(pemRepresentation: normalized) {
            return NIOSSHPrivateKey(p256Key: key)
        }

        if let key = try? P384.Signing.PrivateKey(pemRepresentation: normalized) {
            return NIOSSHPrivateKey(p384Key: key)
        }

        if let key = try? P521.Signing.PrivateKey(pemRepresentation: normalized) {
            return NIOSSHPrivateKey(p521Key: key)
        }

        throw SessionError.unsupportedPrivateKey
    }

    private static func parseOpenSSHPrivateKey(_ pemRepresentation: String) throws -> NIOSSHPrivateKey {
        let base64Payload = pemRepresentation
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()

        guard let data = Data(base64Encoded: base64Payload) else {
            throw SessionError.invalidPrivateKey
        }

        var reader = OpenSSHReader(data: data)
        guard try reader.readCString() == "openssh-key-v1" else {
            throw SessionError.invalidPrivateKey
        }

        let cipherName = try reader.readString()
        let kdfName = try reader.readString()
        _ = try reader.readData()
        let keyCount = try reader.readUInt32()

        guard cipherName == "none", kdfName == "none", keyCount == 1 else {
            throw SessionError.unsupportedPrivateKey
        }

        _ = try reader.readData()
        let privateSection = try reader.readData()
        return try parseOpenSSHPrivateSection(privateSection)
    }

    private static func parseOpenSSHPrivateSection(_ data: Data) throws -> NIOSSHPrivateKey {
        var reader = OpenSSHReader(data: data)
        let check1 = try reader.readUInt32()
        let check2 = try reader.readUInt32()

        guard check1 == check2 else {
            throw SessionError.invalidPrivateKey
        }

        let keyType = try reader.readString()
        guard keyType == "ssh-ed25519" else {
            throw SessionError.unsupportedPrivateKey
        }

        let publicKey = try reader.readData()
        let privateKeyBlob = try reader.readData()
        _ = try reader.readString()

        guard publicKey.count == 32, privateKeyBlob.count == 64 else {
            throw SessionError.invalidPrivateKey
        }

        let privateSeed = privateKeyBlob.prefix(32)
        let expectedPublicKey = privateKeyBlob.suffix(32)
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateSeed)

        guard Data(expectedPublicKey) == signingKey.publicKey.rawRepresentation,
              publicKey == signingKey.publicKey.rawRepresentation else {
            throw SessionError.invalidPrivateKey
        }

        return NIOSSHPrivateKey(ed25519Key: signingKey)
    }
}

extension TerminiSSHSession {
    private enum SessionError: LocalizedError {
        case invalidChannelType
        case invalidPrivateKey
        case unsupportedPrivateKey

        var errorDescription: String? {
            switch self {
            case .invalidChannelType:
                return "The SSH server returned an unexpected channel type."
            case .invalidPrivateKey:
                return "The SSH private key is malformed."
            case .unsupportedPrivateKey:
                return "The SSH private key type isn't supported by this demo."
            }
        }
    }

    final class ClientAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
        private let username: String
        private let password: String?
        private let privateKey: NIOSSHPrivateKey?
        private var didOfferPassword = false
        private var didOfferPrivateKey = false
        private let lock = NSLock()
        private var exhausted = false
        private var lastOfferedMethods: NIOSSHAvailableUserAuthenticationMethods?

        /// Whether every credential was offered and the server still asked for more.
        var hasExhaustedOffers: Bool {
            lock.withLock { exhausted }
        }

        /// The methods the server last said it accepts.
        var offeredMethods: NIOSSHAvailableUserAuthenticationMethods? {
            lock.withLock { lastOfferedMethods }
        }

        /// Whether the server accepts passwords and none was given, so asking for one could still sign in.
        var couldUsePassword: Bool {
            lock.withLock { password == nil && lastOfferedMethods?.contains(.password) == true }
        }

        init(username: String, password: String?, privateKey: NIOSSHPrivateKey?) {
            self.username = username
            self.password = password
            self.privateKey = privateKey
        }

        func nextAuthenticationType(
            availableMethods: NIOSSHAvailableUserAuthenticationMethods,
            nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
        ) {
            lock.withLock { lastOfferedMethods = availableMethods }
            if let privateKey, !didOfferPrivateKey, availableMethods.contains(.publicKey) {
                didOfferPrivateKey = true
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(
                        username: username,
                        serviceName: "",
                        offer: .privateKey(.init(privateKey: privateKey))
                    )
                )
                return
            }

            if let password, !didOfferPassword, availableMethods.contains(.password) {
                didOfferPassword = true
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(
                        username: username,
                        serviceName: "",
                        offer: .password(.init(password: password))
                    )
                )
                return
            }

            lock.withLock { exhausted = true }
            nextChallengePromise.succeed(nil)
        }
    }

    private final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
        private let host: String
        private let port: Int
        private let policy: TerminiSSHHostKeyPolicy
        private let pinnedFingerprint: String?
        private let store: TerminiSSHKnownHostsStore
        private let onNote: (@Sendable (String) -> Void)?

        init(
            host: String,
            port: Int,
            policy: TerminiSSHHostKeyPolicy,
            pinnedFingerprint: String?,
            store: TerminiSSHKnownHostsStore = .shared,
            onNote: (@Sendable (String) -> Void)? = nil
        ) {
            self.host = host
            self.port = port
            self.policy = policy
            self.pinnedFingerprint = pinnedFingerprint
            self.store = store
            self.onNote = onNote
        }

        func validateHostKey(
            hostKey: NIOSSHPublicKey,
            validationCompletePromise: EventLoopPromise<Void>
        ) {
            do {
                let presentedKey = try TerminiKnownHostKey(hostKey: hostKey)
                let result = try store.validate(
                    presentedKey: presentedKey,
                    host: host,
                    port: port,
                    policy: policy,
                    pinnedFingerprint: pinnedFingerprint
                )

                if case .trustedNewHost(let entry) = result {
                    onNote?("Trusted new host key \(entry.fingerprint) for \(entry.host):\(entry.port)")
                }

                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }

    private final class ConnectionErrorHandler: ChannelInboundHandler {
        typealias InboundIn = Any

        private let onError: @Sendable (Error) -> Void
        private let onAuthenticated: @Sendable () -> Void

        init(onError: @escaping @Sendable (Error) -> Void, onAuthenticated: @escaping @Sendable () -> Void) {
            self.onError = onError
            self.onAuthenticated = onAuthenticated
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if event is UserAuthSuccessEvent {
                onAuthenticated()
            }
            context.fireUserInboundEventTriggered(event)
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            onError(error)
            context.close(promise: nil)
        }
    }

    private final class ChannelHandler: ChannelDuplexHandler {
        typealias InboundIn = SSHChannelData
        typealias OutboundIn = ByteBuffer
        typealias OutboundOut = SSHChannelData

        private let term: String
        // Non-nil → request exec(command) instead of a shell.
        private let execCommand: String?
        private let requestsPseudoTerminal: Bool
        private let initialColumns: Int
        private let initialRows: Int
        private let initialPixelWidth: Int
        private let initialPixelHeight: Int
        private let onReady: @Sendable (Channel) -> Void
        private let onOutput: @Sendable (Data) -> Void
        private let onExit: @Sendable (Int?) -> Void
        private let onError: @Sendable (Error) -> Void

        init(
            term: String,
            execCommand: String? = nil,
            requestsPseudoTerminal: Bool = true,
            initialColumns: Int,
            initialRows: Int,
            initialPixelWidth: Int,
            initialPixelHeight: Int,
            onReady: @escaping @Sendable (Channel) -> Void,
            onOutput: @escaping @Sendable (Data) -> Void,
            onExit: @escaping @Sendable (Int?) -> Void,
            onError: @escaping @Sendable (Error) -> Void
        ) {
            self.term = term
            self.execCommand = execCommand
            self.requestsPseudoTerminal = requestsPseudoTerminal
            self.initialColumns = initialColumns
            self.initialRows = initialRows
            self.initialPixelWidth = initialPixelWidth
            self.initialPixelHeight = initialPixelHeight
            self.onReady = onReady
            self.onOutput = onOutput
            self.onExit = onExit
            self.onError = onError
        }

        func handlerAdded(context: ChannelHandlerContext) {
            context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { [onError] error in
                onError(error)
            }
        }

        func channelActive(context: ChannelHandlerContext) {
            // tmux decides whether a client is UTF-8 capable from the SSH
            // session locale. Without these requests, servers commonly start
            // the shell in the C locale and tmux substitutes Nerd Font and
            // other non-ASCII cells with underscores before bytes ever reach
            // Termini's renderer.
            for (name, value) in [
                ("LANG", "en_US.UTF-8"),
                ("LC_CTYPE", "en_US.UTF-8"),
            ] {
                context.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.EnvironmentRequest(
                        wantReply: false,
                        name: name,
                        value: value
                    ),
                    promise: nil
                )
            }

            // RFC 8160 reserves opcode 42 for IUTF8. NIOSSH intentionally
            // supports raw opcodes so clients can negotiate modes newer than
            // its named convenience constants.
            let iutf8 = SSHTerminalModes.Opcode(rawValue: 42)
            let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: term,
                terminalCharacterWidth: initialColumns,
                terminalRowHeight: initialRows,
                terminalPixelWidth: initialPixelWidth,
                terminalPixelHeight: initialPixelHeight,
                terminalModes: SSHTerminalModes([iutf8: 1])
            )

            let ptyPromise = context.eventLoop.makePromise(of: Void.self)
            let shellPromise = context.eventLoop.makePromise(of: Void.self)

            // Exec the command directly when configured.
            let execCommand = self.execCommand
            ptyPromise.futureResult.whenSuccess {
                if let execCommand {
                    context.triggerUserOutboundEvent(
                        SSHChannelRequestEvent.ExecRequest(command: execCommand, wantReply: true),
                        promise: shellPromise
                    )
                } else {
                    context.triggerUserOutboundEvent(
                        SSHChannelRequestEvent.ShellRequest(wantReply: true),
                        promise: shellPromise
                    )
                }
            }

            ptyPromise.futureResult.whenFailure { [onError] error in
                onError(error)
            }

            // The channel travels with the reply, so a session can close it if the attempt it opened for is gone.
            let channel = context.channel
            shellPromise.futureResult.whenSuccess { [onReady] in
                onReady(channel)
            }

            shellPromise.futureResult.whenFailure { [onError] error in
                onError(error)
            }

            if requestsPseudoTerminal {
                context.triggerUserOutboundEvent(ptyRequest, promise: ptyPromise)
            } else {
                ptyPromise.succeed(())
            }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let message = unwrapInboundIn(data)
            guard case .byteBuffer(let bytes) = message.data else { return }
            // Without a PTY, stderr arrives separately; it isn't part of the command's output stream.
            if !requestsPseudoTerminal, message.type != .channel { return }

            let output = Data(bytes.readableBytesView)
            guard !output.isEmpty else { return }
            onOutput(output)
        }

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            let buffer = unwrapOutboundIn(data)
            let message = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            context.write(wrapOutboundOut(message), promise: promise)
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            switch event {
            case let exit as SSHChannelRequestEvent.ExitStatus:
                onExit(exit.exitStatus)
            case is SSHChannelRequestEvent.ExitSignal:
                onExit(nil)
            case let channelEvent as ChannelEvent where channelEvent == .inputClosed:
                onExit(nil)
            default:
                context.fireUserInboundEventTriggered(event)
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            onError(error)
            context.close(promise: nil)
        }
    }

    private struct OpenSSHReader {
        private let data: Data
        private var offset = 0

        init(data: Data) {
            self.data = data
        }

        mutating func readCString() throws -> String {
            guard let terminator = data[offset...].firstIndex(of: 0) else {
                throw SessionError.invalidPrivateKey
            }

            let valueData = data[offset..<terminator]
            offset = terminator + 1

            guard let value = String(data: valueData, encoding: .utf8) else {
                throw SessionError.invalidPrivateKey
            }

            return value
        }

        mutating func readString() throws -> String {
            let value = try readData()
            guard let string = String(data: value, encoding: .utf8) else {
                throw SessionError.invalidPrivateKey
            }
            return string
        }

        mutating func readData() throws -> Data {
            let length = try Int(readUInt32())
            guard offset + length <= data.count else {
                throw SessionError.invalidPrivateKey
            }

            let slice = data[offset..<(offset + length)]
            offset += length
            return Data(slice)
        }

        mutating func readUInt32() throws -> UInt32 {
            guard offset + 4 <= data.count else {
                throw SessionError.invalidPrivateKey
            }

            let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { partial, byte in
                (partial << 8) | UInt32(byte)
            }
            offset += 4
            return value
        }
    }
}
