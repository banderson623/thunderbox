import SwiftUI

struct AddFolderSheet: View {
    let scan: ScanResult
    @EnvironmentObject var store: ServiceStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<UUID> = []
    @State private var serversOnly = false
    @State private var customCommand = ""
    @State private var customName = ""

    private var candidates: [ScriptCandidate] {
        serversOnly ? scan.candidates.filter(\.isServer) : scan.candidates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if scan.candidates.isEmpty {
                emptyScan
            } else {
                List {
                    Section {
                        ForEach(candidates) { c in
                            candidateRow(c)
                        }
                    } header: {
                        HStack {
                            Text("Discovered scripts").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Toggle("Servers only", isOn: $serversOnly).toggleStyle(.checkbox)
                                .font(.caption)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()
            customSection
            Divider()
            footer
        }
        .frame(width: 640, height: 520)
        .background(WoodsBackground())
        .foregroundStyle(Theme.textPrimary)
        .scrollContentBackground(.hidden)
        .onAppear {
            // Pre-select the servers — that's the primary use case.
            selected = Set(scan.candidates.filter(\.isServer).map(\.id))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Add from folder").font(.headline)
            Text(compact(scan.folder)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Text("\(scan.candidates.filter(\.isServer).count) server\(scan.candidates.filter(\.isServer).count == 1 ? "" : "s") · \(scan.candidates.count) total")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private func candidateRow(_ c: ScriptCandidate) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(c.id) },
            set: { on in if on { selected.insert(c.id) } else { selected.remove(c.id) } }
        )) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.name).font(.body.weight(.medium))
                        if c.isServer {
                            Text("server")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.20), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                        if let p = c.declaredPort {
                            Text(":\(p)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(c.command).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
            }
        }
        .toggleStyle(.checkbox)
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or add a custom command").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Name", text: $customName)
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                TextField("e.g. python3 scripts/status.py", text: $customCommand)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Runs in \(compact(scan.folder)) via your zsh environment.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Add") { addSelected() }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty && customCommand.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
    }

    private var emptyScan: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
            Text("No npm scripts, shell scripts, or Python servers found").foregroundStyle(.secondary)
            Text("You can still add a custom command below.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private func addSelected() {
        var toAdd: [Service] = scan.candidates
            .filter { selected.contains($0.id) }
            .map { $0.makeService() }

        let cmd = customCommand.trimmingCharacters(in: .whitespaces)
        if !cmd.isEmpty {
            let name = customName.trimmingCharacters(in: .whitespaces).isEmpty
                ? (scan.folder as NSString).lastPathComponent
                : customName.trimmingCharacters(in: .whitespaces)
            let score = ScriptScanner.serverScore(command: cmd, name: name)
            toAdd.append(Service(
                name: name, folder: scan.folder, command: cmd, kind: .custom,
                isServer: score >= 3, declaredPort: ScriptScanner.parsePort(in: cmd)))
        }

        store.add(toAdd)
        dismiss()
    }

    private func compact(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
