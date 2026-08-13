import Foundation
import SwiftUI

/// How a service is invoked.
enum ServiceKind: String, Codable, Hashable {
    case npm        // `npm run <scriptName>`
    case shell      // a `*.sh` file, run with its interpreter
    case python     // a `*.py` file that looks like it starts a server
    case custom     // an arbitrary command line the user typed

    var label: String {
        switch self {
        case .npm: return "npm"
        case .shell: return "shell"
        case .python: return "python"
        case .custom: return "custom"
        }
    }
}

/// Runtime lifecycle of a service.
enum RunState: Equatable {
    case idle        // never started (or reset) this session
    case starting    // launched, no confirmation yet
    case running     // process alive
    case stopped     // exited cleanly (code 0) or stopped by the user
    case failed(code: Int32)  // crashed / non-zero exit
    case blocked     // refused to launch: its port is already taken

    var isActive: Bool {
        switch self {
        case .starting, .running: return true
        default: return false
        }
    }
}

/// Why a service could not take its port, and what to do about it.
struct PortConflict: Equatable {
    let port: Int
    /// The process squatting on it, when lsof can see it (same-user processes only).
    let holder: PortHolder?
    /// Another Thunderbox service, if the holder matches one we launched.
    var ownedByServiceID: UUID?
    /// An env var the failing tool itself named as the way to move the port —
    /// scraped from its output, e.g. `BOOK_READER_PORT`.
    var suggestedVar: String?
    /// A free port to move to.
    var suggestedPort: Int?

    var summary: String {
        if let holder {
            return "Port \(port) is held by \(holder.command) (pid \(holder.pid))."
        }
        return "Port \(port) is already in use."
    }
}

/// Codable form persisted to disk. Only the definition — never runtime state.
struct ServiceDTO: Codable, Identifiable {
    var id: UUID
    var name: String
    var folder: String
    var command: String
    var kind: ServiceKind
    var isServer: Bool
    /// A port parsed from the command at add-time, if any (best-effort hint).
    var declaredPort: Int?
    /// Extra environment for the launched process, layered over the inherited shell env.
    var env: [String: String] = [:]
    /// Which env var moves this project's port. No universal standard exists — `PORT` is
    /// the common case, but plenty of projects pick their own (`BOOK_READER_PORT`,
    /// `STREAMLIT_SERVER_PORT`), so it's recorded per service.
    var portVar: String?
    /// Pick the next free port automatically instead of failing on a conflict.
    /// Requires `portVar` — without a knob to turn there's nothing to move.
    var autoPort: Bool = false
    /// Publish this service to the LAN through a relay while it runs.
    var lanExposed: Bool = false
    /// Port the relay listens on. Defaults to the service's own port.
    var lanPort: Int?

    init(id: UUID, name: String, folder: String, command: String, kind: ServiceKind,
         isServer: Bool, declaredPort: Int? = nil, env: [String: String] = [:],
         portVar: String? = nil, autoPort: Bool = false,
         lanExposed: Bool = false, lanPort: Int? = nil) {
        self.id = id
        self.name = name
        self.folder = folder
        self.command = command
        self.kind = kind
        self.isServer = isServer
        self.declaredPort = declaredPort
        self.env = env
        self.portVar = portVar
        self.autoPort = autoPort
        self.lanExposed = lanExposed
        self.lanPort = lanPort
    }

    /// Hand-written so service lists saved before these fields existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        folder = try c.decode(String.self, forKey: .folder)
        command = try c.decode(String.self, forKey: .command)
        kind = try c.decode(ServiceKind.self, forKey: .kind)
        isServer = try c.decode(Bool.self, forKey: .isServer)
        declaredPort = try c.decodeIfPresent(Int.self, forKey: .declaredPort)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        portVar = try c.decodeIfPresent(String.self, forKey: .portVar)
        autoPort = try c.decodeIfPresent(Bool.self, forKey: .autoPort) ?? false
        lanExposed = try c.decodeIfPresent(Bool.self, forKey: .lanExposed) ?? false
        lanPort = try c.decodeIfPresent(Int.self, forKey: .lanPort)
    }
}

/// Runtime service: stable definition + observable live state.
final class Service: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var folder: String
    @Published var command: String
    @Published var kind: ServiceKind
    @Published var isServer: Bool
    @Published var declaredPort: Int?
    @Published var env: [String: String]
    @Published var portVar: String?
    @Published var autoPort: Bool
    @Published var lanExposed: Bool
    @Published var lanPort: Int?

    // Live state (not persisted)
    @Published var state: RunState = .idle
    @Published var detectedURL: URL?
    @Published var lanBinding: LANBinding = .unknown
    @Published var memoryMB: Double?
    @Published var pid: Int32?
    @Published var lastStartedAt: Date?
    /// Set when a launch was refused, or when output revealed a port collision.
    @Published var conflict: PortConflict?
    /// The port this run actually took — may differ from `declaredPort` when `autoPort`
    /// moved it, or when the output revealed a port we hadn't parsed.
    @Published var activePort: Int?
    /// Where the LAN relay is reachable, while it's up.
    @Published var lanURL: URL?

    init(dto: ServiceDTO) {
        self.id = dto.id
        self.name = dto.name
        self.folder = dto.folder
        self.command = dto.command
        self.kind = dto.kind
        self.isServer = dto.isServer
        self.declaredPort = dto.declaredPort
        self.env = dto.env
        self.portVar = dto.portVar
        self.autoPort = dto.autoPort
        self.lanExposed = dto.lanExposed
        self.lanPort = dto.lanPort
    }

    init(name: String, folder: String, command: String, kind: ServiceKind,
         isServer: Bool, declaredPort: Int? = nil) {
        self.id = UUID()
        self.name = name
        self.folder = folder
        self.command = command
        self.kind = kind
        self.isServer = isServer
        self.declaredPort = declaredPort
        self.env = [:]
        self.portVar = nil
        self.autoPort = false
        self.lanExposed = false
        self.lanPort = nil
    }

    var dto: ServiceDTO {
        ServiceDTO(id: id, name: name, folder: folder, command: command,
                   kind: kind, isServer: isServer, declaredPort: declaredPort,
                   env: env, portVar: portVar, autoPort: autoPort,
                   lanExposed: lanExposed, lanPort: lanPort)
    }

    /// The port a launch will ask for: an explicit override in `env` if there is one,
    /// otherwise whatever was parsed from the command. Deliberately ignores `activePort`,
    /// which is a *result* of a run — feeding it back in would let a one-off automatic
    /// move disagree with the environment the next launch actually gets.
    var configuredPort: Int? {
        if let portVar, let raw = env[portVar], let p = Int(raw) { return p }
        return declaredPort
    }

    /// The port to talk about in the UI: what the current run took, else what's configured.
    var effectivePort: Int? { activePort ?? configuredPort }

    /// Folder shown compactly with ~ for home.
    var displayFolder: String {
        let home = NSHomeDirectory()
        if folder.hasPrefix(home) {
            return "~" + folder.dropFirst(home.count)
        }
        return folder
    }
}
