import SwiftUI

struct ServiceRow: View {
    @ObservedObject var service: Service
    var onEdit: (Service) -> Void = { _ in }
    @EnvironmentObject var store: ServiceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 13) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(service.name).font(.title3.weight(.semibold))
                    if service.isServer {
                        Text("server")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.20), in: Capsule())
                            .foregroundStyle(Theme.accent)
                    }
                    Text(service.kind.label)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(service.command)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(service.displayFolder)
                HStack(spacing: 12) {
                    if service.state != .idle {
                        Text(service.state.label)
                            .font(.callout.weight(service.state.isActive ? .semibold : .regular))
                            .foregroundStyle(service.state.color)
                    }
                    if let url = service.detectedURL {
                        Link(destination: url) {
                            Label(url.absoluteString, systemImage: "link").font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.amber)
                    }
                    if let lan = service.lanURL {
                        Link(destination: lan) {
                            Label(lan.absoluteString, systemImage: "wifi").font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .help("Reachable from other machines on this network")
                    }
                    if let mb = service.memoryMB {
                        Label(formatMB(mb), systemImage: "memorychip")
                            .font(.callout).foregroundStyle(Theme.textSecondary)
                    }
                }
                if let conflict = service.conflict { conflictStrip(conflict) }
            }

            Spacer()
            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(cardStroke, lineWidth: cardStrokeWidth))
                .shadow(color: cardGlow, radius: 11)
        )
        .opacity(isDormant ? 0.82 : 1.0)
        .contextMenu {
            Button("Edit…") { onEdit(service) }
            Menu("Icon") {
                Button("Choose Image…") {
                    if let img = ImageIntake.chooseFile() { store.setIcon(img, for: service) }
                }
                Button("Paste Image") {
                    if let img = ImageIntake.fromPasteboard() { store.setIcon(img, for: service) }
                }
                .disabled(!ImageIntake.pasteboardHasImage)
                if store.icon(for: service) != nil {
                    Button("Remove Icon", role: .destructive) { store.clearIcon(for: service) }
                }
            }
            Toggle("Expose on LAN", isOn: Binding(
                get: { service.lanExposed },
                set: { store.setLANExposed($0, for: service) }))
            .disabled(!service.isServer)
            Button("Reveal in Finder") { revealInFinder() }
            Button("Open Console") { openConsole() }
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(service.command, forType: .string)
            }
            Divider()
            Button("Remove", role: .destructive) { store.remove(service) }
        }
    }

    /// Shown instead of a bare red exit code when a launch lost the race for its port.
    /// Every button here is a way out: take the port, move off it, or just open what's
    /// already answering — which is often what the user actually wanted.
    @ViewBuilder private func conflictStrip(_ conflict: PortConflict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(conflict.summary, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(Theme.amber)

            HStack(spacing: 8) {
                if let other = conflict.ownedByServiceID.flatMap({ store.service(id: $0) }) {
                    Button("Stop \(other.name) & start") { store.resolveConflict(for: service) }
                } else if let holder = conflict.holder {
                    Button("Stop \(holder.command) (\(holder.pid)) & start") {
                        store.resolveConflict(for: service)
                    }
                }
                if let variable = conflict.suggestedVar, let port = conflict.suggestedPort {
                    Button("Use \(variable)=\(port)") { store.retryOnFreePort(service) }
                        .help("Relaunch on port \(port) and remember \(variable) for next time")
                }
                if let url = URL(string: "http://localhost:\(conflict.port)") {
                    Link("Open :\(conflict.port)", destination: url)
                }
            }
            .font(.callout)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.top, 2)
    }

    // Leading project avatar: custom icon or a placeholder tile, with the status dot as a
    // corner badge (glows when the service is active).
    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Theme.surface
                if let icon = store.icon(for: service) {
                    Image(nsImage: icon).resizable().interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: service.isServer ? "server.rack" : "terminal")
                        .font(.system(size: 16)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.surfaceStroke, lineWidth: 1))

            Circle()
                .fill(service.state.color)
                .frame(width: 13, height: 13)
                .overlay(Circle().stroke(Theme.bgBottom, lineWidth: 2))
                .shadow(color: service.state.color.opacity(service.state.isActive ? 0.9 : 0),
                        radius: service.state.isActive ? 5 : 0)
                .offset(x: 4, y: 4)
        }
        .frame(width: 44, height: 44)
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            if service.state.isActive {
                Button(role: .destructive) { store.stop(service) } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(Theme.danger)
            } else {
                Button { store.start(service) } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .tint(Theme.accent)
            }

            Button { openConsole() } label: {
                Image(systemName: "terminal")
            }
            .help("Open console (stdout / stderr)")

            Button { onEdit(service) } label: {
                Image(systemName: "pencil")
            }
            .help("Edit command")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    // MARK: - Card emphasis (running "lights up", failed glows red, idle/stopped recede)

    private var isDormant: Bool {
        switch service.state { case .idle, .stopped: return true; default: return false }
    }

    private var cardFill: Color {
        switch service.state {
        case .running, .starting: return Theme.accent.opacity(0.16)
        case .failed:             return Theme.danger.opacity(0.12)
        case .blocked:            return Theme.amber.opacity(0.12)
        default:                  return Theme.surface
        }
    }

    private var cardStroke: Color {
        switch service.state {
        case .running, .starting: return Theme.accent.opacity(0.75)
        case .failed:             return Theme.danger.opacity(0.65)
        case .blocked:            return Theme.amber.opacity(0.65)
        default:                  return Theme.surfaceStroke
        }
    }

    private var cardStrokeWidth: CGFloat { service.state.isActive || cardIsFlagged ? 1.6 : 1 }

    /// Failed or blocked — either way the card should assert itself.
    private var cardIsFlagged: Bool {
        switch service.state { case .failed, .blocked: return true; default: return false }
    }

    private var cardGlow: Color {
        switch service.state {
        case .running, .starting: return Theme.accent.opacity(0.40)
        case .failed:             return Theme.danger.opacity(0.30)
        case .blocked:            return Theme.amber.opacity(0.30)
        default:                  return .clear
        }
    }

    private func openConsole() {
        _ = store.runner(for: service)   // ensure a runner exists to capture output
        openWindow(id: "console", value: service.id)
    }

    /// Open Finder at the service's folder. If the command points at a local script
    /// (e.g. `./run.sh`), select that file specifically.
    private func revealInFinder() {
        let fm = FileManager.default
        // First whitespace-delimited token, stripped of a leading "./".
        let firstToken = service.command
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let relative = firstToken.hasPrefix("./") ? String(firstToken.dropFirst(2)) : firstToken
        let scriptPath = (service.folder as NSString).appendingPathComponent(relative)

        let target: URL
        if !relative.isEmpty, fm.fileExists(atPath: scriptPath) {
            target = URL(fileURLWithPath: scriptPath)         // select the script file
        } else {
            target = URL(fileURLWithPath: service.folder, isDirectory: true)  // reveal the folder
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func formatMB(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}
