import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: ServiceStore
    @State private var scanResult: ScanResult?
    @State private var editorMode: ServiceEditor.Mode?
    @State private var showServersOnly = false
    @State private var scanning = false

    private var visibleServices: [Service] {
        showServersOnly ? store.services.filter(\.isServer) : store.services
    }

    var body: some View {
        ZStack {
            WoodsBackground()
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.surfaceStroke)
                if store.services.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(visibleServices) { service in
                            ServiceRow(service: service, onEdit: { editorMode = .edit($0) })
                                .environmentObject(store)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                        }
                        .onMove { source, dest in
                            store.move(from: source, to: dest, visibleIDs: visibleServices.map(\.id))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 0)
                }
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .sheet(item: $scanResult) { result in
            AddFolderSheet(scan: result).environmentObject(store)
        }
        .sheet(item: $editorMode) { mode in
            ServiceEditor(mode: mode).environmentObject(store)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Thunderbox").font(.title3.bold())
                Text(statusLine).font(.callout).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if scanning { ProgressView().controlSize(.small).padding(.trailing, 4) }
            Toggle("Servers only", isOn: $showServersOnly)
                .toggleStyle(.checkbox)
                .disabled(store.services.isEmpty)
            if store.runningCount > 0 {
                Button(role: .destructive) { stopAll() } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
            }
            Button { editorMode = .add } label: {
                Label("Add Command…", systemImage: "text.cursor")
            }
            .help("Type a command manually")
            Button { addFolder() } label: {
                Label("Add Folder…", systemImage: "plus")
            }
            .keyboardShortcut("o", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusLine: String {
        let total = store.services.count
        let running = store.runningCount
        if total == 0 { return "No services yet" }
        return "\(total) service\(total == 1 ? "" : "s") · \(running) running"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 50)).foregroundStyle(Theme.textSecondary)
            Text("No services yet").font(.title2.bold())
            Text("Add a project folder to discover its runnable scripts —\nservers that start web apps are listed first — or add a command by hand.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .font(.body)
            HStack(spacing: 10) {
                Button { addFolder() } label: { Label("Add Folder…", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent.opacity(0.85))
                Button { editorMode = .add } label: { Label("Add Command…", systemImage: "text.cursor") }
            }
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a project folder to scan for runnable scripts."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        scanning = true
        let path = url.path
        DispatchQueue.global(qos: .userInitiated).async {
            let candidates = ScriptScanner.scan(folder: path)
            DispatchQueue.main.async {
                scanning = false
                scanResult = ScanResult(folder: path, candidates: candidates)
            }
        }
    }

    private func stopAll() {
        for s in store.services where s.state.isActive { store.stop(s) }
    }
}

/// Wraps a scan so it can drive `.sheet(item:)`.
struct ScanResult: Identifiable {
    let id = UUID()
    let folder: String
    let candidates: [ScriptCandidate]
}
