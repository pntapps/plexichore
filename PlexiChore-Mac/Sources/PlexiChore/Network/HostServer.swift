import Foundation
import Network

/// TCP server on port 47800 (Network.framework, TCP_NODELAY).
final class HostServer: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case starting
        case listening
        case failed(String)
    }

    private let queue = DispatchQueue(label: "plexi.listener", qos: .userInitiated)
    private var listener: NWListener?
    private var retryWork: DispatchWorkItem?

    /// Called on an arbitrary queue for each accepted connection (not yet started).
    var onNewSession: (@Sendable (ClientSession) -> Void)?
    /// Called on an arbitrary queue.
    var onStateChange: (@Sendable (State) -> Void)?

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.retryWork?.cancel()
            self.retryWork = nil
            self.listener?.cancel()
            self.listener = nil
            self.onStateChange?(.stopped)
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        onStateChange?(.starting)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = 10
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false

        guard let port = NWEndpoint.Port(rawValue: PlexiProtocol.tcpPort) else { return }
        let l: NWListener
        do {
            l = try NWListener(using: params, on: port)
        } catch {
            onStateChange?(.failed("Cannot listen on \(PlexiProtocol.tcpPort): \(error.localizedDescription)"))
            scheduleRetry()
            return
        }

        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.listening)
            case .failed(let error):
                self.onStateChange?(.failed("Listener failed: \(error.localizedDescription)"))
                l?.cancel()
                if self.listener === l { self.listener = nil }
                self.scheduleRetry()
            case .waiting(let error):
                self.onStateChange?(.failed("Waiting: \(error.localizedDescription)"))
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let session = ClientSession(connection: connection)
            self.onNewSession?(session)
        }
        listener = l
        l.start(queue: queue)
    }

    private func scheduleRetry() {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startOnQueue() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
