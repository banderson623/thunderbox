import SwiftUI
import AppKit

/// Add a brand-new command, or edit an existing service's command/folder/name.
/// Use when folder scanning didn't surface the right script, or to tweak one later.
struct ServiceEditor: View {
    enum Mode: Identifiable {
        case add
        case edit(Service)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let s): return s.id.uuidString
            }
        }
    }

    /// One user-entered environment variable, with a stable identity so the rows keep
    /// their focus while being typed into.
    private struct EnvRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    let mode: Mode
    @EnvironmentObject var store: ServiceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var folder = ""
    @State private var command = ""
    @State private var isServer = false
    @State private var serverEdited = false   // did the user override the auto guess?
    @State private var iconImage: NSImage?
    @State private var iconDirty = false

    @State private var portVar = ""           // "" means none chosen
    @State private var portValue = ""
    @State private var autoPort = false
    @State private var lanExposed = false
    @State private var candidates: [PortVarCandidate] = []
    @State private var envRows: [EnvRow] = []

    private var isEdit: Bool { if case .edit = mode { return true }; return false }
    private var canSave: Bool {
        !command.trimmingCharacters(in: .whitespaces).isEmpty && !folder.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEdit ? "Edit command" : "Add command")
                .font(.title3.bold()).foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    iconSection

                    field("Name") {
                        TextField("e.g. dashboard", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    field("Folder") {
                        HStack(spacing: 8) {
                            TextField("/path/to/project", text: $folder)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1).truncationMode(.head)
                            Button("Choose…") { chooseFolder() }
                        }
                    }

                    field("Command") {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("e.g. python3 scripts/status.py", text: $command, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...4)
                                .font(.system(.body, design: .monospaced))
                                .onChange(of: command) { _, new in
                                    if !serverEdited {
                                        isServer = ScriptScanner.serverScore(command: new, name: name) >= 3
                                    }
                                }
                            Text("Runs via your zsh environment (nvm / rye / PATH) in the folder above.")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { isServer },
                        set: { isServer = $0; serverEdited = true })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("This starts a web server")
                            Text("Servers are grouped at the top and get URL / port detection.")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.accent)

                    if isServer {
                        Divider().overlay(Theme.surfaceStroke)
                        portSection
                        Divider().overlay(Theme.surfaceStroke)
                        lanSection
                    }

                    Divider().overlay(Theme.surfaceStroke)
                    envSection
                }
                .padding(.bottom, 8)
            }

            HStack {
                if isEdit, case .edit(let s) = mode {
                    Button(role: .destructive) { store.remove(s); dismiss() } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 560, height: 640)
        .background(WoodsBackground())
        .foregroundStyle(Theme.textPrimary)
        .onAppear(perform: load)
    }

    // MARK: - Port

    /// The project decides which variable moves its port, so this offers what was actually
    /// found in the project — `.env` declarations and `process.env.…` reads — rather than
    /// assuming everyone honours `PORT`.
    private var portSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Port").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)

            HStack(spacing: 8) {
                Picker("", selection: $portVar) {
                    Text("Not set").tag("")
                    ForEach(candidates) { candidate in
                        Text(candidate.name).tag(candidate.name)
                    }
                    if !portVar.isEmpty, !candidates.contains(where: { $0.name == portVar }) {
                        Text(portVar).tag(portVar)     // hand-typed or previously saved
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)

                Text("=").foregroundStyle(Theme.textSecondary)

                TextField("4321", text: $portValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .disabled(portVar.isEmpty)
            }

            if let source = candidates.first(where: { $0.name == portVar })?.source {
                Text("Found in \(source).")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else if portVar.isEmpty {
                Text("No override. Thunderbox will still warn before launching into a taken port.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }

            Toggle("Move to the next free port if this one's taken", isOn: $autoPort)
                .toggleStyle(.checkbox)
                .font(.callout)
                .disabled(portVar.isEmpty)
                .help(portVar.isEmpty
                      ? "Needs a port variable — there's nothing to change without one."
                      : "On a conflict, set \(portVar) to the next free port instead of failing.")
        }
    }

    // MARK: - LAN

    private var lanSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Network").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)

            Toggle("Expose on the local network while running", isOn: $lanExposed)
                .toggleStyle(.switch)
                .tint(Theme.accent)

            if lanExposed {
                let target = Int(portValue) ?? ScriptScanner.parsePort(in: command) ?? 0
                VStack(alignment: .leading, spacing: 3) {
                    if target > 0 {
                        // String() so the locale's grouping separator stays out of port numbers.
                        Text("Relays 0.0.0.0:\(String(ServiceRunner.defaultLANPort(for: target))) → localhost:\(String(target)), so the server doesn't need to bind to anything but loopback.")
                    } else {
                        Text("Relays a LAN port to whatever port the service turns out to use.")
                    }
                    ForEach(store.lanAddresses) { address in
                        Text("Reachable at \(address.ip) (\(address.label)).")
                    }
                    Text("No authentication sits in front of it — anyone on the network can reach it. macOS will ask once whether Thunderbox may accept incoming connections.")
                        .foregroundStyle(Theme.amber)
                }
                .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Environment

    private var envSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Environment").font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    envRows.append(EnvRow(key: "", value: ""))
                } label: {
                    Label("Add", systemImage: "plus").font(.caption)
                }
                .buttonStyle(.borderless)
            }

            if envRows.isEmpty {
                Text("Set on top of your shell environment when this service launches.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }

            ForEach($envRows) { $row in
                HStack(spacing: 6) {
                    TextField("KEY", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    Text("=").foregroundStyle(Theme.textSecondary)
                    TextField("value", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    Button {
                        envRows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var iconSection: some View {
        HStack(spacing: 14) {
            ZStack {
                Theme.surface
                if let img = iconImage {
                    Image(nsImage: img).resizable().interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").font(.system(size: 22))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.surfaceStroke, lineWidth: 1))

            VStack(alignment: .leading, spacing: 6) {
                Text("Project icon").font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    Button("Choose…") {
                        if let i = ImageIntake.chooseFile() { iconImage = i; iconDirty = true }
                    }
                    Button("Paste") {
                        if let i = ImageIntake.fromPasteboard() { iconImage = i; iconDirty = true }
                    }
                    .disabled(!ImageIntake.pasteboardHasImage)
                    if iconImage != nil {
                        Button("Remove", role: .destructive) { iconImage = nil; iconDirty = true }
                    }
                }
                Text("Select an image, or copy one and paste.")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
    }

    @ViewBuilder private func field<Content: View>(_ label: String,
                                                   @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    // MARK: - Load / save

    private func load() {
        if case .edit(let s) = mode {
            name = s.name; folder = s.folder; command = s.command; isServer = s.isServer
            serverEdited = true
            iconImage = store.icon(for: s)
            portVar = s.portVar ?? ""
            portValue = s.portVar.flatMap { s.env[$0] } ?? s.declaredPort.map(String.init) ?? ""
            autoPort = s.autoPort
            lanExposed = s.lanExposed
            envRows = s.env
                .filter { $0.key != s.portVar }
                .sorted { $0.key < $1.key }
                .map { EnvRow(key: $0.key, value: $0.value) }
        }
        discoverPortVars()
    }

    /// Scanning a repo touches the filesystem, so keep it off the main thread; the picker
    /// fills in a moment later.
    private func discoverPortVars() {
        let folder = folder, command = command
        guard !folder.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = PortVarFinder.candidates(folder: folder, command: command)
            DispatchQueue.main.async {
                candidates = found
                // Offer the project's own default when nothing is set yet.
                if portVar.isEmpty, portValue.isEmpty,
                   let best = found.first(where: { $0.defaultValue != nil }) {
                    portVar = best.name
                    portValue = best.defaultValue.map(String.init) ?? ""
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                name = url.lastPathComponent
            }
            discoverPortVars()
        }
    }

    private func save() {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        let nm = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? (folder as NSString).lastPathComponent
            : name.trimmingCharacters(in: .whitespaces)

        var env: [String: String] = [:]
        for row in envRows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            env[key] = row.value
        }
        let chosenVar = portVar.trimmingCharacters(in: .whitespaces)
        let chosenPort = Int(portValue.trimmingCharacters(in: .whitespaces))
        if !chosenVar.isEmpty, let chosenPort {
            env[chosenVar] = String(chosenPort)
        }
        // An explicit override is more authoritative than a port scraped from the command.
        let port = chosenPort ?? ScriptScanner.parsePort(in: cmd)

        switch mode {
        case .add:
            let svc = Service(name: nm, folder: folder, command: cmd, kind: .custom,
                              isServer: isServer, declaredPort: port)
            svc.env = env
            svc.portVar = chosenVar.isEmpty ? nil : chosenVar
            svc.autoPort = autoPort
            svc.lanExposed = lanExposed
            store.add([svc])
            if let img = iconImage { store.setIcon(img, for: svc) }
        case .edit(let s):
            s.name = nm; s.folder = folder; s.command = cmd
            s.isServer = isServer; s.declaredPort = port
            s.env = env
            s.portVar = chosenVar.isEmpty ? nil : chosenVar
            s.autoPort = autoPort
            let lanChanged = s.lanExposed != lanExposed
            s.lanExposed = lanExposed
            store.update(s)
            if lanChanged { store.setLANExposed(lanExposed, for: s) }
            if iconDirty {
                if let img = iconImage { store.setIcon(img, for: s) } else { store.clearIcon(for: s) }
            }
        }
        dismiss()
    }
}
