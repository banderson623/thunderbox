import Foundation
import SwiftUI
import Darwin

/// The app's single source of truth: the persisted service list + live runners.
@MainActor
final class ServiceStore: ObservableObject {
    @Published var services: [Service] = []
    private var runners: [UUID: ServiceRunner] = [:]

    private let fileURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thunderbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("services.json")
        load()
    }

    // MARK: - Runner access

    func runner(for service: Service) -> ServiceRunner {
        if let r = runners[service.id] { return r }
        let r = ServiceRunner(service: service)
        runners[service.id] = r
        return r
    }

    // MARK: - Mutations

    func add(_ newServices: [Service]) {
        // Append new services in the order given (scan results already arrive servers-first).
        // We never re-sort the existing list — the user's manual drag order is authoritative.
        for s in newServices {
            // De-dupe by folder+command.
            if services.contains(where: { $0.folder == s.folder && $0.command == s.command }) {
                continue
            }
            services.append(s)
        }
        save()
    }

    /// Persist edits to an existing service (name / folder / command / isServer changed).
    /// Does not move the service — its position in the manual order is preserved.
    func update(_ service: Service) {
        save()
        objectWillChange.send()
    }

    func remove(_ service: Service) {
        runner(for: service).stop()
        runners[service.id] = nil
        clearIcon(for: service)
        services.removeAll { $0.id == service.id }
        save()
    }

    // MARK: - Project icons

    /// Bumped whenever any icon changes so views re-render.
    @Published private(set) var iconVersion = 0
    private var iconCache: [UUID: NSImage] = [:]

    private var iconsDir: URL {
        let dir = fileURL.deletingLastPathComponent().appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func iconURL(for id: UUID) -> URL {
        iconsDir.appendingPathComponent(id.uuidString + ".png")
    }

    func icon(for service: Service) -> NSImage? {
        if let cached = iconCache[service.id] { return cached }
        guard let img = NSImage(contentsOf: iconURL(for: service.id)) else { return nil }
        iconCache[service.id] = img
        return img
    }

    func setIcon(_ image: NSImage, for service: Service) {
        let sized = Self.downscaled(image, maxDim: 256)
        guard let data = Self.pngData(sized) else { return }
        try? data.write(to: iconURL(for: service.id), options: .atomic)
        iconCache[service.id] = sized
        iconVersion += 1
    }

    func clearIcon(for service: Service) {
        try? FileManager.default.removeItem(at: iconURL(for: service.id))
        iconCache[service.id] = nil
        iconVersion += 1
    }

    private static func downscaled(_ image: NSImage, maxDim: CGFloat) -> NSImage {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return image }
        let scale = min(1, maxDim / max(s.width, s.height))
        if scale >= 1 { return image }
        let newSize = NSSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
        let out = NSImage(size: newSize)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: s), operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Drag-to-reorder. `visibleIDs` is the order currently on screen (which may be a filtered
    /// subset). Visible rows are rearranged into the dragged order while any hidden services
    /// keep their absolute slots, so reordering works even with "Servers only" on.
    func move(from source: IndexSet, to destination: Int, visibleIDs: [UUID]) {
        var ids = visibleIDs
        ids.move(fromOffsets: source, toOffset: destination)

        let byID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        let visibleSet = Set(visibleIDs)
        var queue = ids
        services = services.map { s in
            guard visibleSet.contains(s.id) else { return s }   // hidden: stays put
            return byID[queue.removeFirst()] ?? s               // visible: next in dragged order
        }
        save()
    }

    // MARK: - Control

    func start(_ service: Service) { runner(for: service).start() }
    func stop(_ service: Service) { runner(for: service).stop() }
    func restart(_ service: Service) { runner(for: service).restart() }

    var runningCount: Int { services.filter { $0.state.isActive }.count }

    /// Stop every active service. Called on quit. Sends SIGTERM to each group, waits, then
    /// escalates to SIGKILL, blocking briefly so nothing is orphaned.
    func stopAllForQuit() {
        let active = services.filter { $0.state.isActive }
        guard !active.isEmpty else { return }
        var pids: [Int32] = []
        for s in active {
            if let pid = s.pid { pids.append(pid); kill(-pid, SIGTERM) }
        }
        // Give them up to ~3s to exit, then SIGKILL any survivors.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            let anyAlive = pids.contains { kill(-$0, 0) == 0 }
            if !anyAlive { return }
            usleep(100_000)
        }
        for pid in pids where kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let dtos = try? JSONDecoder().decode([ServiceDTO].self, from: data) else { return }
        services = dtos.map(Service.init(dto:))   // preserve saved (manual) order
    }

    func save() {
        let dtos = services.map(\.dto)
        guard let data = try? JSONEncoder().encode(dtos) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
