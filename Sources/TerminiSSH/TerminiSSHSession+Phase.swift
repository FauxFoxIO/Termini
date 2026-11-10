import Foundation
import NIOCore

extension TerminiSSHSession {
    /// One connection attempt. Every callback an attempt registers carries its `id`; events from any other attempt
    /// are dropped, and the resources they bring are closed.
    struct Attempt {
        let id: UInt64
        let authentication: ClientAuthenticationDelegate
        /// Typed into the shell once it is ready; `nil` in exec mode or without a startup command.
        let typedStartupCommand: String?
    }

    /// The open transport and the session channel that runs on it.
    struct Link {
        let transport: TerminiSSHTransportConnection
        let shell: Channel
    }

    /// How far a connecting attempt has come. Each stage owns the resources opened so far.
    enum Stage {
        /// Opening the transport. A child channel exists only after the transport does, so nothing here can be ready.
        case opening(authenticated: Bool)
        /// Transport open; key exchange, user authentication and the session channel request are running.
        case handshaking(TerminiSSHTransportConnection, authenticated: Bool)
        /// Session channel open, so authentication is done; waiting for the shell or exec reply.
        case startingSession(Link)

        var isAuthenticated: Bool {
            switch self {
            case .opening(let authenticated), .handshaking(_, let authenticated):
                return authenticated
            case .startingSession:
                return true
            }
        }
    }

    /// Why an attempt failed, kept after its resources are gone.
    struct Failure {
        let reason: TerminiSSHFailure
        let message: String
        let serverOffersPublicKeys: Bool?
    }

    /// The session's state. The public ``Status`` is derived from it; each case owns the transport and channels it
    /// needs, so a phase that is left releases them.
    enum Phase {
        case disconnected
        case connecting(Attempt, Stage)
        case connected(Attempt, Link)
        case failed(Failure)

        /// The attempt this phase belongs to; `nil` when no attempt is live.
        var attempt: Attempt? {
            switch self {
            case .connecting(let attempt, _), .connected(let attempt, _):
                return attempt
            case .disconnected, .failed:
                return nil
            }
        }

        /// The session channel, once it is open.
        var link: Link? {
            switch self {
            case .connecting(_, .startingSession(let link)), .connected(_, let link):
                return link
            case .connecting, .disconnected, .failed:
                return nil
            }
        }

        /// What leaving this phase closes.
        var owned: Release {
            switch self {
            case .connecting(_, .handshaking(let transport, _)):
                return Release(transport: transport)
            case .connecting(_, .startingSession(let link)), .connected(_, let link):
                return Release(transport: link.transport, shell: link.shell)
            case .connecting, .disconnected, .failed:
                return Release()
            }
        }
    }

    /// Something that happened to an attempt. The session applies it only while that attempt is current.
    enum Event {
        case transportOpened(TerminiSSHTransportConnection)
        case authenticated
        case shellOpened(Channel)
        case ready(Channel)
        case remoteExited(Int?)
        case failed(any Error)

        /// The resources the event brought, which a session that no longer wants them closes.
        var carried: Release {
            switch self {
            case .transportOpened(let transport):
                return Release(transport: transport)
            case .shellOpened(let shell), .ready(let shell):
                return Release(shell: shell)
            case .authenticated, .remoteExited, .failed:
                return Release()
            }
        }
    }

    /// The transport and channel a phase change gave up, closed by whoever caused the change.
    struct Release {
        var transport: TerminiSSHTransportConnection?
        var shell: Channel?

        func close() async {
            if let shell {
                try? await shell.close().get()
            }
            if let transport {
                await transport.close()
            }
        }

        /// Starts the teardown without waiting, for deinitialization.
        func closeWithoutWaiting() {
            shell?.close(promise: nil)
            transport?.closeWithoutWaiting()
        }
    }
}

extension TerminiSSHSession.Status {
    init(_ phase: TerminiSSHSession.Phase) {
        switch phase {
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .failed(let failure):
            self = .failed(failure.message)
        }
    }
}
