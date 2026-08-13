import Foundation
import SystemConfiguration
import dnssd
import CoreImage
import AppKit

/// How a listening server is bound, as far as LAN reachability is concerned.
enum LANBinding: Equatable {
    case unknown          // not checked yet / couldn't tell
    case allInterfaces    // *:port or a LAN IP — reachable from other devices
    case localhostOnly    // 127.0.0.1 / ::1 — invisible to the rest of the network
}

/// Everything Thunderbox knows about being reachable from other devices on the
/// local network: the Mac's Bonjour hostname, per-service `.local` URLs, and a
/// check of which interface a server actually bound to.
enum LANPresence {

    /// The Mac's Bonjour hostname with the `.local` suffix (e.g. "Brians-MacBook.local").
    /// This is what Apple devices on the same network resolve via mDNS, and it stays
    /// stable across reboots and DHCP lease changes — unlike the raw IP address.
    static let localHostname: String = {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? {
            return name + ".local"
        }
        // Fallback: ProcessInfo host name usually already ends in ".local".
        let host = ProcessInfo.processInfo.hostName
        return host.hasSuffix(".local") ? host : host + ".local"
    }()

    /// Rewrite a detected localhost URL so other devices on the network can use it:
    /// same scheme/port/path, host swapped for the Mac's `.local` name.
    static func lanURL(from url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.host = localHostname
        return comps.url
    }

    /// Ask `lsof` who is listening on `port` and whether the socket accepts LAN
    /// connections. A server that prints "http://localhost:3000" may be bound to
    /// either 127.0.0.1 (phone can't reach it) or 0.0.0.0 (phone can) — the banner
    /// doesn't say, so we look at the real socket.
    static func checkBinding(port: Int, completion: @escaping (LANBinding) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            task.arguments = ["-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch {
                DispatchQueue.main.async { completion(.unknown) }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)

            var sawLoopback = false
            var sawListener = false
            for line in text.split(separator: "\n").dropFirst() {   // drop header row
                // NAME is the only whitespace-delimited field containing ":".
                guard let name = line.split(separator: " ").last(where: { $0.contains(":") })
                else { continue }
                sawListener = true
                // NAME looks like "*:3000", "127.0.0.1:3000", "[::1]:3000", "192.168.1.5:3000".
                if name.hasPrefix("*") || name.hasPrefix("[::]:") {
                    DispatchQueue.main.async { completion(.allInterfaces) }
                    return
                }
                if name.hasPrefix("127.") || name.hasPrefix("[::1]") {
                    sawLoopback = true
                } else {
                    // Bound to a specific non-loopback address — reachable on that interface.
                    DispatchQueue.main.async { completion(.allInterfaces) }
                    return
                }
            }
            DispatchQueue.main.async {
                completion(sawListener && sawLoopback ? .localhostOnly : .unknown)
            }
        }
    }

    /// Render a QR code for a URL (black on white so any camera reads it).
    static func qrCode(for url: URL, sidePixels: CGFloat = 320) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = sidePixels / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

/// Publishes one running server on the network via Bonjour/mDNS (`_http._tcp`), so
/// network-browsing apps see it by name. Registration lives exactly as long as this
/// object holds the DNSServiceRef — call `stop()` (or let it deinit) to withdraw it.
final class BonjourAdvertiser {
    private var ref: DNSServiceRef?

    /// Advertise `name` as an HTTP service on `port`. Repeat calls re-register.
    func advertise(name: String, port: Int) {
        stop()
        guard port > 0, port < 65536 else { return }
        var newRef: DNSServiceRef?
        let err = DNSServiceRegister(
            &newRef,
            0,                              // flags: let mDNSResponder rename on conflict
            0,                              // all interfaces
            name, "_http._tcp", nil, nil,
            UInt16(port).bigEndian,
            0, nil,                         // no TXT record
            nil, nil)                       // no callback needed; daemon holds the record
        if err == kDNSServiceErr_NoError { ref = newRef }
    }

    func stop() {
        if let r = ref { DNSServiceRefDeallocate(r) }
        ref = nil
    }

    deinit { stop() }
}
