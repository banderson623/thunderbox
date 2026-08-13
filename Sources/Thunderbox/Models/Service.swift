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

    var isActive: Bool {
        switch self {
        case .starting, .running: return true
        default: return false
        }
    }

    var canRestart: Bool {
        switch self {
        case .stopped, .failed: return true
        default: return false
        }
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

    // Live state (not persisted)
    @Published var state: RunState = .idle
    @Published var detectedURL: URL?
    @Published var lanBinding: LANBinding = .unknown
    @Published var memoryMB: Double?
    @Published var pid: Int32?
    @Published var lastStartedAt: Date?

    init(dto: ServiceDTO) {
        self.id = dto.id
        self.name = dto.name
        self.folder = dto.folder
        self.command = dto.command
        self.kind = dto.kind
        self.isServer = dto.isServer
        self.declaredPort = dto.declaredPort
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
    }

    var dto: ServiceDTO {
        ServiceDTO(id: id, name: name, folder: folder, command: command,
                   kind: kind, isServer: isServer, declaredPort: declaredPort)
    }

    /// Folder shown compactly with ~ for home.
    var displayFolder: String {
        let home = NSHomeDirectory()
        if folder.hasPrefix(home) {
            return "~" + folder.dropFirst(home.count)
        }
        return folder
    }
}
