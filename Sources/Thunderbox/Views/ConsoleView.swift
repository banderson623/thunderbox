import SwiftUI
import AppKit

/// Top-level window content: resolves the service id → live runner.
struct ConsoleWindow: View {
    let serviceID: UUID?
    @EnvironmentObject var store: ServiceStore

    var body: some View {
        if let id = serviceID, let service = store.services.first(where: { $0.id == id }) {
            ConsoleView(service: service, runner: store.runner(for: service))
                .environmentObject(store)
        } else {
            VStack {
                Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary)
                Text("This service no longer exists.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ConsoleView: View {
    @ObservedObject var service: Service
    @ObservedObject var runner: ServiceRunner
    @EnvironmentObject var store: ServiceStore
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.surfaceStroke)
            logBody
        }
        .background(WoodsBackground())
        .foregroundStyle(Theme.textPrimary)
        .navigationTitle(service.name)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Circle().fill(service.state.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).font(.headline)
                HStack(spacing: 8) {
                    Text(service.state.label).font(.caption).foregroundStyle(service.state.color)
                    if let mb = service.memoryMB {
                        Text(mb >= 1024 ? String(format: "%.2f GB", mb/1024) : String(format: "%.0f MB", mb))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let url = service.detectedURL {
                        Link(url.absoluteString, destination: url)
                            .font(.caption).foregroundStyle(Theme.amber)
                    }
                }
            }
            Spacer()
            controls
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var controls: some View {
        Toggle("Auto-scroll", isOn: $autoScroll).toggleStyle(.checkbox).font(.caption)
        if service.state.canRestart {
            Button { store.restart(service) } label: { Image(systemName: "arrow.clockwise") }
                .help("Restart")
        }
        if service.state.isActive {
            Button(role: .destructive) { store.stop(service) } label: { Image(systemName: "stop.fill") }
                .tint(.red).help("Stop")
        } else {
            Button { store.start(service) } label: { Image(systemName: "play.fill") }
                .tint(.green).help("Start")
        }
        Button { runner.clearLog() } label: { Image(systemName: "trash") }.help("Clear")
        Button { copyAll() } label: { Image(systemName: "doc.on.doc") }.help("Copy all")
    }

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(runner.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(Theme.console)
            .onChange(of: runner.lines.count) { _, _ in
                if autoScroll { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear {
                if autoScroll { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func color(for line: LogLine) -> Color {
        if line.text.hasPrefix("» ") { return Theme.amber.opacity(0.9) }   // system notes
        if line.text.hasPrefix("$ ") { return Theme.textSecondary }        // the launched cmd
        return line.isError ? Theme.danger : Theme.textPrimary             // stderr vs stdout
    }

    private func copyAll() {
        let text = runner.lines.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
