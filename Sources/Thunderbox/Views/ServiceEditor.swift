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

    private var isEdit: Bool { if case .edit = mode { return true }; return false }
    private var canSave: Bool {
        !command.trimmingCharacters(in: .whitespaces).isEmpty && !folder.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEdit ? "Edit command" : "Add command")
                .font(.title3.bold()).foregroundStyle(Theme.textPrimary)

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

            Spacer(minLength: 0)

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
        }
        .padding(20)
        .frame(width: 540, height: 486)
        .background(WoodsBackground())
        .foregroundStyle(Theme.textPrimary)
        .onAppear(perform: load)
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

    private func load() {
        if case .edit(let s) = mode {
            name = s.name; folder = s.folder; command = s.command; isServer = s.isServer
            serverEdited = true
            iconImage = store.icon(for: s)
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
        }
    }

    private func save() {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        let nm = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? (folder as NSString).lastPathComponent
            : name.trimmingCharacters(in: .whitespaces)
        let port = ScriptScanner.parsePort(in: cmd)

        switch mode {
        case .add:
            let svc = Service(name: nm, folder: folder, command: cmd, kind: .custom,
                              isServer: isServer, declaredPort: port)
            store.add([svc])
            if let img = iconImage { store.setIcon(img, for: svc) }
        case .edit(let s):
            s.name = nm; s.folder = folder; s.command = cmd
            s.isServer = isServer; s.declaredPort = port
            store.update(s)
            if iconDirty {
                if let img = iconImage { store.setIcon(img, for: s) } else { store.clearIcon(for: s) }
            }
        }
        dismiss()
    }
}
