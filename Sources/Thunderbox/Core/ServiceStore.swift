import Foundation
import SwiftUI
import Combine
import Darwin

/// The app's single source of truth: the persisted service list + live runners.
@MainActor
final class ServiceStore: ObservableObject {
    @Published var services: [Service] = []
    private var runners: [UUID: ServiceRunner] = [:]
    private var serviceObservers: [UUID: AnyCancellable] = [:]

    /// LAN status page a phone can open; publishes its URL once listening.
    let dashboard = DashboardServer()

    private let fileURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thunderbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("services.json")
        load()
        dashboard.start { [weak self] in self?.dashboardEntries ?? [] }
    }

    private var dashboardEntries: [DashboardEntry] {
        services.map { s in
            let failed: Bool = { if case .failed = s.state { return true }; return false }()
            return DashboardEntry(
                name: s.name,
                command: s.command,
                stateLabel: s.state.label,
                isActive: s.state.isActive,
                isFailed: failed,
                isServer: s.isServer,
                // The relay's address wins when it's up: it listens on its own port, so
                // rewriting the service's detected URL would point the phone at a port
                // nothing answers on.
                lanURL: s.lanURL ?? (s.lanBinding == .allInterfaces
                    ? s.detectedURL.flatMap(LANPresence.lanURL(from:)) : nil),
                localhostOnly: s.lanBinding == .localhostOnly,
                memoryMB: s.memoryMB)
        }
    }

    // MARK: - Runner access

    func runner(for service: Service) -> ServiceRunner {
        if let r = runners[service.id] { return r }
        let r = ServiceRunner(service: service)
        // Lets a port conflict say "books is holding it" instead of "pid 11461 is".
        r.identifyHolder = { [weak self] pid in self?.serviceOwning(pid: pid) }
        runners[service.id] = r
        return r
    }

    // MARK: - Mutations

    /// Views that read derived state (running count, isServer filter) observe the store, not
    /// each service — so any live-state change on a service must republish the store.
    private func observe(_ service: Service) {
        serviceObservers[service.id] = service.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    func add(_ newServices: [Service]) {
        // Append new services in the order given (scan results already arrive servers-first).
        // We never re-sort the existing list — the user's manual drag order is authoritative.
        for s in newServices {
            // De-dupe by folder+command.
            if services.contains(where: { $0.folder == s.folder && $0.command == s.command }) {
                continue
            }
            services.append(s)
            observe(s)
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
        serviceObservers[service.id] = nil
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

    // MARK: - Port conflicts

    /// Which service — if any — owns the process holding a port. `livePID` is the
    /// setsid leader, so its pid *is* the process group id of everything it spawned;
    /// the listener is typically a `node`/`python` grandchild inside that group.
    func serviceOwning(pid: Int32) -> UUID? {
        let group = getpgid(pid)
        guard group > 0 else { return nil }
        for (id, runner) in runners where runner.livePID == group { return id }
        return nil
    }

    func service(id: UUID) -> Service? { services.first { $0.id == id } }

    /// Stop whatever holds the conflicting port, then start the blocked service. Prefers
    /// the polite path when it's one of ours (SIGTERM to the whole group via its runner)
    /// and falls back to signalling the bare pid for strangers.
    func resolveConflict(for service: Service, thenStart: Bool = true) {
        guard let conflict = service.conflict else { return }
        if let otherID = conflict.ownedByServiceID, let other = self.service(id: otherID) {
            stop(other)
        } else if let holder = conflict.holder {
            kill(holder.pid, SIGTERM)
        }
        guard thenStart else { return }
        // Give the port a moment to be released before reclaiming it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.start(service)
        }
    }

    /// Relaunch on a different port, remembering the variable that moved it.
    func retryOnFreePort(_ service: Service) {
        guard let conflict = service.conflict,
              let variable = conflict.suggestedVar,
              let port = conflict.suggestedPort else { return }
        runner(for: service).retry(settingVar: variable, to: port)
        save()
    }

    /// Services whose declared ports collide — knowable before either one runs.
    var portCollisions: [Int: [Service]] {
        // Configured, not active: this is advice about what the services are set up to do,
        // and a leftover port from a stopped run would hide a real clash.
        let servers = services.filter { $0.isServer && $0.configuredPort != nil }
        return Dictionary(grouping: servers, by: { $0.configuredPort! })
            .filter { $0.value.count > 1 }
    }

    // MARK: - LAN exposure

    func setLANExposed(_ exposed: Bool, for service: Service) {
        service.lanExposed = exposed
        save()
        let r = runner(for: service)
        if exposed {
            if service.state.isActive { r.startLANIfWanted() }
        } else {
            r.stopLAN()
        }
        objectWillChange.send()
    }

    /// Addresses other machines can use to reach this Mac. Empty when offline.
    var lanAddresses: [LANAddress] { PortProbe.lanAddresses() }

    /// Stop every running service before the app exits. Sourced from the live runner
    /// processes (not UI state) so nothing is missed. SIGTERM each process group, wait
    /// briefly for a clean exit, then SIGKILL any survivor. Blocks until the group is gone
    /// so no server outlives the app.
    func stopAllForQuit() {
        let pids = runners.values.compactMap { $0.livePID }
        guard !pids.isEmpty else { return }
        for pid in pids { kill(-pid, SIGTERM) }   // signal the whole group (negative pid)

        // Give them up to ~4s to exit cleanly, then SIGKILL any survivors.
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            if !pids.contains(where: { kill(-$0, 0) == 0 }) { return }
            usleep(100_000)
        }
        for pid in pids where kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let dtos = try? JSONDecoder().decode([ServiceDTO].self, from: data) else { return }
        services = dtos.map(Service.init(dto:))   // preserve saved (manual) order
        services.forEach(observe)
    }

    func save() {
        let dtos = services.map(\.dto)
        guard let data = try? JSONEncoder().encode(dtos) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
