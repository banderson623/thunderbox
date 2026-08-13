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
    /// Guards `listener` and `pairs`. A lock rather than the queue so `stop()` can tear
    /// down synchronously — a restart calls stop-then-start, and an asynchronous cancel
    /// leaves the old listener still holding the port when the new one tries to bind.
    /// It also has to be safe to call from the queue itself (the failure handler does).
    private let lock = NSLock()
    /// Signalled when the listener reports `.cancelled`, which is when the port is free.
    private let cancelled = DispatchSemaphore(value: 0)
    /// Signalled once the listener settles into `.ready` — or fails trying.
    private let becameReady = DispatchSemaphore(value: 0)
    private var startupError: NWError?
    private var didStart = false

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
        let params = NWParameters.tcp
        // Sockets left in TIME_WAIT by the previous run must not block a restart — that's
        // what this option is for. It still refuses when a live listener owns the port,
        // which is the failure worth reporting.
        params.allowLocalEndpointReuse = true
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
            guard let self else { return }
            switch state {
            case .ready:
                self.becameReady.signal()
            case .failed(let error):
                // NWListener binds asynchronously, so a port collision arrives here rather
                // than out of start(). Before start() has returned, hand the error back to
                // it; afterwards it's a live relay dying, which is the callback's job.
                self.lock.lock()
                let duringStartup = !self.didStart
                if duringStartup { self.startupError = error }
                self.lock.unlock()

                if duringStartup {
                    self.becameReady.signal()
                } else {
                    self.onFailure?(error)
                    // Runs on `queue`: tear down without waiting, or stop()'s wait would
                    // deadlock against this very handler.
                    self.teardown(waitingForCancel: false)
                }
            case .cancelled:
                self.cancelled.signal()
            default:
                break
            }
        }

        lock.lock()
        self.listener = listener
        lock.unlock()
        listener.start(queue: queue)

        // Wait for the bind to actually land, so callers learn about a taken port here
        // instead of discovering a dead relay later.
        guard becameReady.wait(timeout: .now() + 5) == .success else {
            teardown(waitingForCancel: false)
            throw Failure.listenerFailed("Timed out waiting for port \(listenPort).")
        }
        lock.lock()
        let error = startupError
        didStart = error == nil
        lock.unlock()

        if let error {
            teardown(waitingForCancel: false)
            if case .posix(let code) = error, code == .EADDRINUSE {
                throw Failure.portUnavailable(listenPort)
            }
            throw Failure.listenerFailed(error.localizedDescription)
        }
    }

    /// Synchronous: returns once the listener has actually reached `.cancelled` and given
    /// the port back. `cancel()` alone only *starts* that — returning early let a restart
    /// collide with its own previous listener. Bounded, because a caller waiting forever on
    /// the network stack is worse than a caller that picks a different port.
    func stop() {
        teardown(waitingForCancel: true)
    }

    private func teardown(waitingForCancel: Bool) {
        lock.lock()
        let listener = self.listener
        let pairs = self.pairs
        self.listener = nil
        self.pairs.removeAll()
        lock.unlock()

        for pair in pairs.values { pair.cancel() }
        guard let listener else { return }
        listener.cancel()
        if waitingForCancel {
            _ = cancelled.wait(timeout: .now() + 2)
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
            guard let self else { return }
            self.lock.lock()
            self.pairs[key] = nil
            self.lock.unlock()
        }
        lock.lock()
        pairs[key] = pair
        lock.unlock()
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
