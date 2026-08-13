import Foundation
import Network

/// A transparent TCP relay: listens on every interface at `listenPort` and forwards each
/// connection byte-for-byte to `localhost:targetPort`.
///
/// This is how Thunderbox puts a service on the LAN without the service cooperating. Most
/// dev servers bind 127.0.0.1 and are therefore invisible to other machines; telling them
/// otherwise means a different flag or env var for every framework (`vite --host`,
/// `next -H`, `uvicorn --host`, `HOST=`, `STREAMLIT_SERVER_ADDRESS=`…). Relaying sidesteps
/// all of it, works on a process that's already running, and can be switched off again
/// without a restart.
///
/// It relays at the TCP layer, not HTTP — the Host header, WebSocket upgrades, SSE and
/// anything else pass through untouched.
final class LANProxy {

    enum Failure: LocalizedError {
        case portUnavailable(Int)
        case listenerFailed(String)

        var errorDescription: String? {
            switch self {
            case .portUnavailable(let p): return "Port \(p) is already in use on this Mac."
            case .listenerFailed(let m): return m
            }
        }
    }

    let listenPort: Int
    let targetPort: Int

    private var listener: NWListener?
    private var pairs: [ObjectIdentifier: Pair] = [:]
    private let queue = DispatchQueue(label: "thunderbox.lanproxy")

    /// Called on `queue` when the listener dies on its own (interface loss, port stolen).
    var onFailure: ((Error) -> Void)?

    init(listenPort: Int, targetPort: Int) {
        self.listenPort = listenPort
        self.targetPort = targetPort
    }

    // MARK: - Lifecycle

    func start() throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: listenPort) ?? 0) else {
            throw Failure.portUnavailable(listenPort)
        }
        // Fail loudly if something already owns the port rather than silently sharing it.
        guard PortProbe.isFree(listenPort) else { throw Failure.portUnavailable(listenPort) }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        params.includePeerToPeer = false

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            throw Failure.listenerFailed(error.localizedDescription)
        }

        listener.newConnectionHandler = { [weak self] inbound in
            self?.accept(inbound)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onFailure?(error)
                self?.stop()
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for pair in self.pairs.values { pair.cancel() }
            self.pairs.removeAll()
        }
    }

    // MARK: - Relaying

    private func accept(_ inbound: NWConnection) {
        // "localhost" rather than a literal 127.0.0.1: some servers (Vite, recent Node)
        // bind only [::1], and letting Network.framework resolve reaches either.
        let outbound = NWConnection(
            host: NWEndpoint.Host("localhost"),
            port: NWEndpoint.Port(rawValue: UInt16(targetPort))!,
            using: .tcp)

        let pair = Pair(inbound: inbound, outbound: outbound)
        let key = ObjectIdentifier(pair)
        pair.onClose = { [weak self] in
            self?.queue.async { self?.pairs[key] = nil }
        }
        queue.async { self.pairs[key] = pair }
        pair.start(on: queue)
    }

    /// One accepted connection and its matching upstream connection, pumped in both
    /// directions until either end closes.
    private final class Pair {
        private let inbound: NWConnection
        private let outbound: NWConnection
        private var closed = false
        var onClose: (() -> Void)?

        init(inbound: NWConnection, outbound: NWConnection) {
            self.inbound = inbound
            self.outbound = outbound
        }

        func start(on queue: DispatchQueue) {
            for connection in [inbound, outbound] {
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed, .cancelled: self?.cancel()
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
            pump(from: inbound, to: outbound)
            pump(from: outbound, to: inbound)
        }

        private func pump(from source: NWConnection, to sink: NWConnection) {
            source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    sink.send(content: data, completion: .contentProcessed { sendError in
                        if sendError != nil { self.cancel() }
                    })
                }
                if isComplete || error != nil {
                    self.cancel()
                    return
                }
                self.pump(from: source, to: sink)
            }
        }

        func cancel() {
            guard !closed else { return }
            closed = true
            inbound.cancel()
            outbound.cancel()
            onClose?()
        }
    }
}
