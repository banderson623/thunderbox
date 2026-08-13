import XCTest
@testable import Thunderbox

/// End-to-end check that the relay really carries traffic: a loopback-only server, a
/// proxy in front of it, and a request that has to travel through both.
final class LANProxyTests: XCTestCase {

    func testRelaysHTTPToALoopbackOnlyServer() throws {
        let origin = try LoopbackServer(body: "hello from the origin")
        defer { origin.stop() }

        let lanPort = try XCTUnwrap(PortProbe.nextFree(from: 21_000))
        let proxy = LANProxy(listenPort: lanPort, targetPort: origin.port)
        try proxy.start()
        defer { proxy.stop() }

        let body = try get("http://127.0.0.1:\(lanPort)/")
        XCTAssertEqual(body, "hello from the origin")
    }

    /// Two requests in a row: the relay must keep accepting after the first pair closes.
    func testRelaysSuccessiveConnections() throws {
        let origin = try LoopbackServer(body: "ok")
        defer { origin.stop() }

        let lanPort = try XCTUnwrap(PortProbe.nextFree(from: 21_000))
        let proxy = LANProxy(listenPort: lanPort, targetPort: origin.port)
        try proxy.start()
        defer { proxy.stop() }

        XCTAssertEqual(try get("http://127.0.0.1:\(lanPort)/"), "ok")
        XCTAssertEqual(try get("http://127.0.0.1:\(lanPort)/"), "ok")
    }

    /// stop() has to leave the port genuinely released, not merely scheduled for release:
    /// a restart calls stop-then-start, and an async teardown made the relay collide with
    /// its own previous listener ("Port 15173 is already in use on this Mac").
    func testStopReleasesThePortForAnImmediateRestart() throws {
        let origin = try LoopbackServer(body: "ok")
        defer { origin.stop() }
        let lanPort = try XCTUnwrap(PortProbe.nextFree(from: 21_000))

        let first = LANProxy(listenPort: lanPort, targetPort: origin.port)
        try first.start()
        XCTAssertEqual(try get("http://127.0.0.1:\(lanPort)/"), "ok")
        first.stop()

        let second = LANProxy(listenPort: lanPort, targetPort: origin.port)
        XCTAssertNoThrow(try second.start(), "the port should be free the instant stop() returns")
        defer { second.stop() }
        XCTAssertEqual(try get("http://127.0.0.1:\(lanPort)/"), "ok")
    }

    func testRefusesAPortThatIsAlreadyTaken() throws {
        let occupied = try TestListener()
        defer { occupied.close() }

        let proxy = LANProxy(listenPort: occupied.port, targetPort: 1234)
        XCTAssertThrowsError(try proxy.start()) { error in
            guard case LANProxy.Failure.portUnavailable(let port) = error else {
                return XCTFail("expected portUnavailable, got \(error)")
            }
            XCTAssertEqual(port, occupied.port)
        }
    }

    // MARK: - Helpers

    private func get(_ urlString: String, timeout: TimeInterval = 5) throws -> String {
        let url = try XCTUnwrap(URL(string: urlString))
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // A relay bug shows up as a hang, so let the expectation time out rather than
        // blocking the whole suite on a socket read.
        let done = expectation(description: "GET \(urlString)")
        var received: String?
        var failure: Error?
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let data { received = String(decoding: data, as: UTF8.self) }
            failure = error
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: timeout + 2)
        if let failure { throw failure }
        return try XCTUnwrap(received)
    }
}

/// A minimal HTTP server bound to 127.0.0.1 only — exactly the shape of dev server the
/// relay exists to reach, invisible to the network on its own.
private final class LoopbackServer {
    let port: Int
    private let fd: Int32
    private var running = true
    private let queue = DispatchQueue(label: "test.origin")

    init(body: String) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            throw Failure.bind
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }

        fd = descriptor
        port = Int(UInt16(bigEndian: assigned.sin_port))
        serve(body: body)
    }

    private func serve(body: String) {
        queue.async { [fd] in
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/plain\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            while self.running {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var scratch = [UInt8](repeating: 0, count: 4096)
                _ = read(client, &scratch, scratch.count)   // drain the request line
                _ = response.withCString { write(client, $0, strlen($0)) }
                Darwin.close(client)
            }
        }
    }

    func stop() {
        running = false
        Darwin.close(fd)
    }

    enum Failure: Error { case socket, bind }
}
