import Foundation

/// What unlocking FileVault on a Mac over SSH did.
public enum TerminiSSHFileVaultUnlockResult: Equatable, Sendable {
    /// The Mac took the password at its startup screen and is unlocking its disk and starting up. It accepts normal
    /// SSH sessions once startup finishes.
    case unlocking
    /// The Mac was already running and signed the password in to an ordinary session; nothing needed unlocking.
    case alreadyRunning
    /// The Mac rejected the password.
    case passwordRejected
    /// The attempt failed before the Mac judged the password.
    case failed(TerminiSSHFailure, String)
}

extension TerminiSSHSession {
    /// How long a session that opened may stay silent before it closes and still count as an unlock.
    static let fileVaultUnlockSilenceWindow: Duration = .seconds(3)

    /// Unlocks FileVault on a Mac that restarted, through the SSH server macOS runs at its startup screen when Remote
    /// Login is on.
    ///
    /// Before FileVault is unlocked, the Mac's disk and its users' `authorized_keys` are encrypted, so only a FileVault
    /// user's password works. The startup screen's server accepts it, unlocks the disk and closes the connection
    /// without opening a session; the Mac then finishes starting up. A Mac that is already running signs the password
    /// in to an ordinary session instead, which this closes at once.
    ///
    /// The configuration's password is the only credential offered; its key and identity are ignored. Its host-key
    /// settings apply as they do to ``connect(configuration:transport:)``. The startup screen may present a host key
    /// other than the running Mac's, so callers typically give it its own `hostKeyAlias`.
    public static func unlockFileVault(
        configuration: TerminiSSHConfiguration,
        transport: TerminiSSHTransport = .tcp
    ) async -> TerminiSSHFileVaultUnlockResult {
        var passwordOnly = configuration
        passwordOnly.identity = nil
        passwordOnly.privateKeyPEM = nil
        passwordOnly.startupCommand = nil
        passwordOnly.useExecRequest = false

        let session = TerminiSSHSession()
        session.showsStatusLines = false
        var receivedBytes = 0
        session.onRawOutput = { data in receivedBytes += data.count }

        await session.connect(configuration: passwordOnly, transport: transport)

        switch session.status {
        case .connected, .connecting:
            // The shell channel opened; its ready reply may still be on the way.
            if let failure = session.failure { return .failed(failure, "") }
            // Some startup screens open a session and close it straight away; a quiet close counts as an unlock.
            let (statusChanges, continuation) = AsyncStream<Status>.makeStream()
            // Setting the handler reports the current status first, then every change.
            session.onStatusChange = { continuation.yield($0) }
            defer {
                session.onStatusChange = nil
                continuation.finish()
            }
            let silenceWindow = fileVaultUnlockSilenceWindow
            let closedQuietly = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask {
                    for await status in statusChanges {
                        switch status {
                        case .disconnected, .failed: return true
                        case .connecting, .connected: continue
                        }
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: silenceWindow)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if closedQuietly, receivedBytes == 0 { return .unlocking }
            await session.disconnect()
            return .alreadyRunning
        case .failed(let message):
            switch session.failure {
            case .closedAfterAuthentication:
                return .unlocking
            case .authenticationFailed, .passwordRequired:
                return .passwordRejected
            case .some(let failure):
                return .failed(failure, message)
            case .none:
                return .failed(.unreachable, message)
            }
        case .disconnected:
            return .failed(session.failure ?? .unreachable, "")
        }
    }
}
