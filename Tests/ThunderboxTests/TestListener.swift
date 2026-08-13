import Foundation
import Darwin

/// A socket bound to an OS-assigned port, so tests have a genuinely occupied port to
/// probe without guessing a number and hoping it's free.
final class TestListener {
    let port: Int
    private let fd: Int32

    init() throws {
        // Kept local until both stored properties are ready — the socket calls below
        // capture it in closures, which `self` isn't allowed to be part of yet.
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                    // let the kernel pick a free one
        addr.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw Failure.bind
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { Darwin.close(descriptor); throw Failure.bind }

        fd = descriptor
        port = Int(UInt16(bigEndian: assigned.sin_port))
    }

    func close() { Darwin.close(fd) }

    enum Failure: Error { case socket, bind }
}
