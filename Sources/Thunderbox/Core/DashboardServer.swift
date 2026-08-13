import Foundation
import Network

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
            let isGet = request.hasPrefix("GET ")
            Task { @MainActor [weak self] in
                let body: String
                let status: String
                if !isGet {
                    status = "405 Method Not Allowed"
                    body = "Method not allowed."
                } else {
                    status = "200 OK"
                    body = Self.renderHTML(entries: self?.entriesProvider() ?? [])
                }
                let payload = Data(body.utf8)
                let head = "HTTP/1.1 \(status)\r\n"
                    + "Content-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(payload.count)\r\n"
                    + "Cache-Control: no-store\r\n"
                    + "Connection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + payload,
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    // MARK: - Page

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A single self-contained page, phone-first, that refreshes itself.
    private static func renderHTML(entries: [DashboardEntry]) -> String {
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
                inner += #"<div class="go">Open ›</div>"#
                cards += "<a class=\"card live\" href=\"\(escape(lan.absoluteString))\">\(inner)</a>\n"
            } else {
                if e.isActive && e.localhostOnly {
                    inner += #"<div class="tag">Mac only</div>"#
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
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="refresh" content="8">
        <title>Thunderbox</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; margin: 0; }
          body { font: -apple-system-body, sans-serif; font-family: -apple-system, system-ui, sans-serif;
                 background: #171a14; color: #e8eadf; padding: 20px 16px 40px;
                 max-width: 560px; margin: 0 auto; }
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
