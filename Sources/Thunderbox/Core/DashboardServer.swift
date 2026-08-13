import Foundation
import Network
import AppKit

/// A snapshot of one service, frozen for rendering on the phone dashboard.
struct DashboardEntry {
    let name: String
    let command: String
    let stateLabel: String
    let isActive: Bool
    let isFailed: Bool
    let isServer: Bool
    let lanURL: URL?          // set only when reachable from other devices
    let localhostOnly: Bool
    let memoryMB: Double?
}

/// Thunderbox's own status page, served over the LAN so a phone in the other
/// room can see what's running. Read-only by design: it lists every service and
/// links to the ones that are reachable; starting/stopping stays on the Mac.
///
/// Listens on the first free port from `candidatePorts` (so the URL is the same
/// every day on an idle system) and broadcasts itself over Bonjour as
/// "Thunderbox" (`_http._tcp`).
@MainActor
final class DashboardServer: ObservableObject {
    /// The LAN address of the dashboard once it's up, e.g. http://my-mac.local:4141
    @Published private(set) var url: URL?

    private var listener: NWListener?
    private let advertiser = BonjourAdvertiser()
    private var entriesProvider: () -> [DashboardEntry] = { [] }
    private let queue = DispatchQueue(label: "thunderbox.dashboard")

    private static let candidatePorts: [UInt16] = [4141, 4142, 4143, 4151]

    func start(entries: @escaping () -> [DashboardEntry]) {
        entriesProvider = entries
        tryListen(portIndex: 0)
    }

    private func tryListen(portIndex: Int) {
        guard portIndex < Self.candidatePorts.count else { return }   // give up quietly
        let port = Self.candidatePorts[portIndex]
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: .tcp, on: nwPort) else {
            tryListen(portIndex: portIndex + 1)
            return
        }

        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.url = URL(string: "http://\(LANPresence.localHostname):\(port)/")
                    self.advertiser.advertise(name: "Thunderbox", port: Int(port))
                case .failed:
                    // Port taken (or otherwise unusable) — move to the next candidate.
                    l.cancel()
                    if self.listener === l {
                        self.listener = nil
                        self.url = nil
                        self.tryListen(portIndex: portIndex + 1)
                    }
                default:
                    break
                }
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            self?.serve(conn)
        }

        listener = l
        l.start(queue: queue)
    }

    // MARK: - One request, one response

    private nonisolated func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
            guard error == nil, let data, !data.isEmpty else { conn.cancel(); return }
            let request = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                let (status, contentType, payload) = self?.respond(to: request)
                    ?? ("503 Service Unavailable", "text/plain", Data("Gone.".utf8))
                let head = "HTTP/1.1 \(status)\r\n"
                    + "Content-Type: \(contentType)\r\n"
                    + "Content-Length: \(payload.count)\r\n"
                    + "Cache-Control: no-store\r\n"
                    + "Connection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + payload,
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    /// Route one parsed request. "/" is the page; the icon + manifest routes make
    /// iOS's Add to Home Screen install it as a proper web app with the app icon.
    private func respond(to request: String) -> (status: String, type: String, body: Data) {
        guard request.hasPrefix("GET ") else {
            return ("405 Method Not Allowed", "text/plain", Data("Method not allowed.".utf8))
        }
        let target = request.dropFirst(4).prefix(while: { $0 != " " })
        let path = target.prefix(while: { $0 != "?" })   // ignore query string

        switch true {
        case path == "/" || path == "/index.html":
            let html = Self.renderHTML(entries: entriesProvider())
            return ("200 OK", "text/html; charset=utf-8", Data(html.utf8))
        case path.hasPrefix("/apple-touch-icon"):        // iOS probes several names/sizes
            if let png = iconPNG(sidePixels: 180) {
                return ("200 OK", "image/png", png)
            }
        case path == "/icon-512.png":
            if let png = iconPNG(sidePixels: 512) {
                return ("200 OK", "image/png", png)
            }
        case path == "/manifest.webmanifest":
            return ("200 OK", "application/manifest+json", Data(Self.manifest.utf8))
        default:
            break
        }
        return ("404 Not Found", "text/plain", Data("Not found.".utf8))
    }

    // MARK: - Web-app install bits

    private static let manifest = """
    {
      "name": "Thunderbox",
      "short_name": "Thunderbox",
      "description": "What's running on the Mac",
      "start_url": "/",
      "display": "standalone",
      "background_color": "#171a14",
      "theme_color": "#171a14",
      "icons": [
        { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png" },
        { "src": "/apple-touch-icon.png", "sizes": "180x180", "type": "image/png" }
      ]
    }
    """

    private var iconPNGCache: [Int: Data] = [:]

    /// The app's own icon (Thunderbox.icns in a packaged build), rendered onto the
    /// page background so iOS home-screen tiles don't get black corners where the
    /// macOS icon shape is transparent.
    private func iconPNG(sidePixels: Int) -> Data? {
        if let cached = iconPNGCache[sidePixels] { return cached }
        guard let icon = NSApplication.shared.applicationIconImage, icon.isValid,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: sidePixels, pixelsHigh: sidePixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: sidePixels, height: sidePixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let full = NSRect(x: 0, y: 0, width: sidePixels, height: sidePixels)
        NSColor(srgbRed: 0x17 / 255.0, green: 0x1a / 255.0, blue: 0x14 / 255.0, alpha: 1).setFill()
        full.fill()
        icon.draw(in: full, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        iconPNGCache[sidePixels] = png
        return png
    }

    // MARK: - Page

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A single self-contained page, phone-first, that refreshes itself.
    /// Not private so tests can check the markup without standing up a listener.
    static func renderHTML(entries: [DashboardEntry]) -> String {
        let running = entries.filter(\.isActive).count
        let subtitle = entries.isEmpty
            ? "No services yet"
            : "\(entries.count) service\(entries.count == 1 ? "" : "s") · \(running) running"

        var cards = ""
        for e in entries {
            let dot = e.isFailed ? "#ff5d5d" : e.isActive ? "#8bd55a" : "#8a8f84"
            let name = escape(e.name)
            let command = escape(e.command)
            var meta = escape(e.stateLabel)
            if let mb = e.memoryMB {
                meta += " · " + (mb >= 1024 ? String(format: "%.2f GB", mb / 1024)
                                            : String(format: "%.0f MB", mb))
            }
            var inner = """
                <div class="dot" style="background:\(dot)"></div>
                <div class="body">
                  <div class="name">\(name)</div>
                  <div class="cmd">\(command)</div>
                  <div class="meta">\(meta)</div>
                </div>
                """
            if let lan = e.lanURL {
                inner += #"<div class="go">Open ↗</div>"#
                // target=_blank so the dashboard survives the tap. It matters most when
                // this is installed to the home screen: standalone mode has no browser
                // chrome and therefore no back button, so navigating in place would strand
                // you inside the service with no way back. From a standalone web app iOS
                // hands the link to Safari, which is the new tab/window that's wanted.
                cards += "<a class=\"card live\" target=\"_blank\" rel=\"noopener\" "
                    + "href=\"\(escape(lan.absoluteString))\">\(inner)</a>\n"
            } else {
                // A running server with no link needs to say why, or it reads as a dead
                // card you can't tap and aren't told anything about. "Checking" is the
                // honest label while the binding probe is still settling — the page
                // refreshes every 8s, so it resolves itself in front of you.
                if e.isActive && e.isServer {
                    inner += e.localhostOnly
                        ? #"<div class="tag">Mac only</div>"#
                        : #"<div class="tag">Checking…</div>"#
                }
                cards += "<div class=\"card\">\(inner)</div>\n"
            }
        }
        if entries.isEmpty {
            cards = #"<div class="empty">Add services in Thunderbox on your Mac.</div>"#
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta http-equiv="refresh" content="8">
        <title>Thunderbox</title>
        <link rel="manifest" href="/manifest.webmanifest">
        <link rel="apple-touch-icon" href="/apple-touch-icon.png">
        <link rel="icon" type="image/png" sizes="512x512" href="/icon-512.png">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-title" content="Thunderbox">
        <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
        <meta name="theme-color" content="#171a14">
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; margin: 0; }
          body { font: -apple-system-body, sans-serif; font-family: -apple-system, system-ui, sans-serif;
                 background: #171a14; color: #e8eadf; max-width: 560px; margin: 0 auto;
                 padding: calc(20px + env(safe-area-inset-top)) 16px
                          calc(40px + env(safe-area-inset-bottom)); }
          h1 { font-size: 22px; }
          .sub { color: #9aa08e; font-size: 14px; margin: 4px 0 18px; }
          .card { display: flex; align-items: center; gap: 12px; padding: 14px;
                  border: 1px solid #2c3227; border-radius: 12px; margin-bottom: 10px;
                  background: #1e2319; text-decoration: none; color: inherit; }
          .card.live { border-color: #4c6b34; background: #222b19; }
          .dot { width: 12px; height: 12px; border-radius: 50%; flex: none; }
          .body { min-width: 0; flex: 1; }
          .name { font-weight: 600; font-size: 16px; }
          .cmd { font-family: ui-monospace, monospace; font-size: 12px; color: #9aa08e;
                 white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-top: 2px; }
          .meta { font-size: 13px; color: #b9bfab; margin-top: 3px; }
          .go { color: #a4d06e; font-weight: 600; font-size: 14px; flex: none; }
          .tag { color: #9aa08e; font-size: 12px; border: 1px solid #2c3227;
                 border-radius: 999px; padding: 2px 8px; flex: none; }
          .empty { color: #9aa08e; text-align: center; padding: 40px 0; }
          footer { color: #6e7463; font-size: 12px; text-align: center; margin-top: 24px; }
        </style>
        </head>
        <body>
        <h1>⚡ Thunderbox</h1>
        <div class="sub">\(escape(subtitle)) · \(escape(LANPresence.localHostname))</div>
        \(cards)
        <footer>Read-only · refreshes every 8 s · start &amp; stop from the Mac</footer>
        </body>
        </html>
        """
    }
}
