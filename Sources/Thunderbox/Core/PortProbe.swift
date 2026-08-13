import Foundation
import Darwin

/// A process holding a TCP port.
struct PortHolder: Equatable {
    let pid: Int32
    let command: String     // "node", "python3"
    let address: String     // "127.0.0.1", "[::1]", "*"

    /// Bound to loopback only — reachable from this Mac, invisible to the LAN.
    /// This is the case a LAN proxy exists to solve.
    var isLoopbackOnly: Bool {
        address == "127.0.0.1" || address == "[::1]" || address == "localhost"
    }
}

/// One usable IPv4 address this Mac answers on.
struct LANAddress: Equatable, Identifiable {
    let interface: String   // "en0"
    let ip: String          // "192.168.1.44"
    var id: String { interface + ip }

    /// Wi-Fi is en0 on Apple silicon laptops; en1+ are Ethernet/Thunderbolt bridges.
    var label: String { interface == "en0" ? "Wi-Fi" : interface }
}

/// Answers "is this port taken, and by whom", finds free ports, and enumerates the
/// addresses this Mac is reachable at. All synchronous and cheap enough to call
/// on a service launch; `holder(of:)` shells out and should stay off the main thread.
enum PortProbe {

    // MARK: - Availability

    /// Can we bind `0.0.0.0:port`? Deliberately does *not* set SO_REUSEADDR, so an
    /// existing listener on any local address (including 127.0.0.1 only) makes this
    /// fail with EADDRINUSE — which is exactly the question being asked.
    static func isFree(_ port: Int) -> Bool {
        guard port > 0, port < 65536 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }   // can't tell; don't block the launch
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// First free port at or after `start`. Returns nil when the whole window is taken,
    /// or when `start` is already past the end of the port range — callers arrive here
    /// having added an offset to an existing port, which can overshoot 65535.
    static func nextFree(from start: Int, window: Int = 200) -> Int? {
        guard start > 0, start < 65_536 else { return nil }
        for port in start..<min(start + window, 65_536) where isFree(port) {
            return port
        }
        return nil
    }

    // MARK: - Ownership

    /// Which process is listening on `port`, via lsof. Nil when the port is free, or
    /// when the listener belongs to another user (lsof won't show it to us unprivileged).
    ///
    /// A nil result therefore means "nobody we can see" — pair it with `isFree` before
    /// concluding the port is available.
    static func holder(of port: Int) -> PortHolder? {
        // -F emits one field per line (p=pid, c=command, n=name), which survives the
        // 9-character COMMAND truncation of lsof's default table output.
        let out = run("/usr/sbin/lsof",
                      ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcn"])
        guard !out.isEmpty else { return nil }

        var pid: Int32?
        var command: String?
        var address: String?
        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value)
            case "c": command = value
            case "n":
                // "n" is "<address>:<port>"; keep the address side.
                if address == nil, let colon = value.lastIndex(of: ":") {
                    address = String(value[value.startIndex..<colon])
                }
            default: break
            }
        }
        guard let pid, let command else { return nil }
        return PortHolder(pid: pid, command: command, address: address ?? "*")
    }

    // MARK: - Reachability

    /// Every non-loopback IPv4 address currently assigned to a live interface.
    /// Skips link-local (169.254/16) and the utun/awdl/bridge interfaces that carry
    /// VPN and peer-to-peer traffic rather than the LAN the user means.
    static func lanAddresses() -> [LANAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [LANAddress] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("eth") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254") else { continue }   // self-assigned, no DHCP
            found.append(LANAddress(interface: name, ip: ip))
        }
        return found
    }

    /// The Mac's Bonjour name — `Brians-MacBook.local`. Nicer to hand someone than a
    /// DHCP address, and it survives the lease changing. Resolvable from Apple devices
    /// and any machine running an mDNS resolver; plain IP is the safer fallback.
    static var localHostName: String? {
        let name = run("/usr/sbin/scutil", ["--get", "LocalHostName"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name + ".local"
    }

    // MARK: - Helpers

    private static func run(_ path: String, _ args: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
