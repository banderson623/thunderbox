import Foundation
import Darwin

/// One line of captured output.
struct LogLine: Identifiable {
    let id: UInt64
    let text: String
    let isError: Bool
    let date: Date
}

/// Owns the lifecycle and output of a single running service.
final class ServiceRunner: ObservableObject {
    unowned let service: Service

    @Published private(set) var lines: [LogLine] = []
    private let maxLines = 5000
    private var lineCounter: UInt64 = 0

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutRemainder = Data()
    private var stderrRemainder = Data()
    private var ramTimer: Timer?
    private var intentionalStop = false
    private var urlLocked = false
    /// Set once output says the port is taken; keeps later lines under scrutiny for the
    /// env var the tool suggests, which is usually printed on the *following* line.
    private var watchingForPortVar = false

    private var proxy: LANProxy?
    private let advertiser = BonjourAdvertiser()

    private let ioQueue = DispatchQueue(label: "thunderbox.io", qos: .utility)

    /// Set by the store so a port conflict can name the other Thunderbox service holding
    /// the port, rather than just a bare pid.
    var identifyHolder: ((Int32) -> UUID?)?

    init(service: Service) {
        self.service = service
    }

    /// The live process-group leader pid, or nil if nothing is running. Used by quit-time
    /// teardown so it acts on real processes rather than UI state.
    var livePID: Int32? {
        guard let p = process, p.isRunning else { return nil }
        return p.processIdentifier
    }

    // MARK: - Lifecycle

    func start() {
        guard !(service.state.isActive) else { return }
        intentionalStop = false
        urlLocked = false
        watchingForPortVar = false
        stdoutRemainder = Data()
        stderrRemainder = Data()

        var overrides = service.env

        // Preflight: if we know which port this wants and something already holds it,
        // don't launch into a guaranteed EADDRINUSE — either move the service or stop and
        // explain, which is far more useful after the fact than a red exit code.
        if let wanted = service.configuredPort, !PortProbe.isFree(wanted) {
            switch resolvePortConflict(wanted: wanted, overrides: &overrides) {
            case .blocked:
                return
            case .moved(let newPort):
                appendSystem("Port \(wanted) is taken — starting on \(newPort) instead.")
            }
        }

        let launchPort = service.portVar.flatMap { overrides[$0] }.flatMap(Int.init)
            ?? service.declaredPort
        DispatchQueue.main.async {
            self.service.conflict = nil
            self.service.activePort = launchPort
        }

        appendSystem("$ (cd \(service.displayFolder)) \(service.command)")
        if !overrides.isEmpty {
            let rendered = overrides.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            appendSystem("env: \(rendered)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // perl setsid() → own session/process group; then exec zsh -ilc to inherit the
        // user's full interactive environment (nvm, rye, PATH from ~/.zshrc).
        // No `exec` before the command: setsid already makes group-kill tear down the whole
        // tree, and letting zsh run the command means compound commands (`A && B`) work and
        // the real exit code propagates (zsh exits with the last command's status).
        let inner = "cd \(shellQuote(service.folder)) && \(service.command)"
        proc.arguments = [
            "-e", "use POSIX qw(setsid); setsid(); exec @ARGV or die $!;",
            "/bin/zsh", "-ilc", inner
        ]
        proc.currentDirectoryURL = URL(fileURLWithPath: service.folder, isDirectory: true)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        // Python block-buffers stdout/stderr when it's a pipe (not a tty); this makes
        // server banners / URLs appear immediately so we can detect and display them.
        env["PYTHONUNBUFFERED"] = "1"
        // Keep logs clean: we color by stream (stderr=red) and strip ANSI ourselves.
        env["FORCE_COLOR"] = env["FORCE_COLOR"] ?? "0"
        // Per-service overrides win over the inherited shell environment — that's the
        // point of them. An exported PORT in ~/.zshrc must not beat an explicit setting.
        for (key, value) in overrides { env[key] = value }
        proc.environment = env

        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.handleData(h.availableData, isError: false)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.handleData(h.availableData, isError: true)
        }

        proc.terminationHandler = { [weak self] p in
            self?.handleTermination(p)
        }

        do {
            try proc.run()
        } catch {
            appendSystem("Failed to launch: \(error.localizedDescription)")
            setState(.failed(code: -1))
            return
        }

        self.process = proc
        let pid = proc.processIdentifier
        DispatchQueue.main.async {
            self.service.pid = pid
            self.service.state = .starting
            self.service.lastStartedAt = Date()
            self.service.memoryMB = nil
            self.service.detectedURL = launchPort.flatMap {
                URL(string: "http://localhost:\($0)")
            }
            self.service.lanBinding = .unknown
            if self.service.detectedURL != nil { self.scheduleLANCheck() }
        }
        startRamTimer(pid: pid)
        // If it survives a moment, call it running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.process?.isRunning == true,
                  self.service.state == .starting else { return }
            self.service.state = .running
            self.startLANIfWanted()
        }
    }

    func stop() {
        stopLAN()
        guard let proc = process, proc.isRunning else { return }
        intentionalStop = true
        let pid = proc.processIdentifier
        appendSystem("Stopping (SIGTERM → process group \(pid))…")
        // Signal the whole process group (negative pid).
        kill(-pid, SIGTERM)
        ioQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, let p = self.process, p.isRunning else { return }
            self.appendSystem("Still alive after 5s — SIGKILL.")
            kill(-pid, SIGKILL)
        }
    }

    func restart() {
        if process?.isRunning == true {
            stop()
            // Wait for termination, then relaunch.
            ioQueue.asyncAfter(deadline: .now() + 6) { [weak self] in
                DispatchQueue.main.async { self?.start() }
            }
        } else {
            start()
        }
    }

    func clearLog() {
        DispatchQueue.main.async { self.lines.removeAll() }
    }

    // MARK: - Port conflicts

    private enum ConflictOutcome {
        case blocked
        case moved(Int)
    }

    /// Decide what to do about a port that's already taken. Moves the service when it has
    /// a knob to turn and the user asked for that; otherwise refuses to launch and records
    /// who's holding the port so the UI can offer a way out.
    private func resolvePortConflict(wanted: Int,
                                     overrides: inout [String: String]) -> ConflictOutcome {
        let holder = PortProbe.holder(of: wanted)

        if service.autoPort, let portVar = service.portVar,
           let free = PortProbe.nextFree(from: wanted + 1) {
            overrides[portVar] = String(free)
            return .moved(free)
        }

        var conflict = PortConflict(port: wanted, holder: holder)
        conflict.ownedByServiceID = holder.flatMap { identifyHolder?($0.pid) }
        conflict.suggestedVar = service.portVar
        conflict.suggestedPort = PortProbe.nextFree(from: wanted + 1)

        appendSystem(conflict.summary)
        if holder?.isLoopbackOnly == true {
            appendSystem("Bound to loopback only — it's something on this Mac, not the network.")
        }
        DispatchQueue.main.async {
            self.service.conflict = conflict
            self.service.state = .blocked
            self.service.detectedURL = URL(string: "http://localhost:\(wanted)")
        }
        return .blocked
    }

    /// Relaunch on a specific port by setting `variable` for this run and keeping it, so
    /// the choice sticks. Drives the "retry on 4322" remedy in the UI.
    func retry(settingVar variable: String, to port: Int) {
        service.portVar = variable
        service.env[variable] = String(port)
        service.declaredPort = port
        service.activePort = nil
        start()
    }

    // MARK: - LAN exposure

    /// The port the relay listens on. It cannot be the service's own port — the server
    /// already holds that on loopback and binding 0.0.0.0 to it would collide — so the
    /// default shifts by 10000 (4321 → 14321), which stays recognisable.
    static func defaultLANPort(for target: Int) -> Int {
        let shifted = target + 10_000
        let candidate = shifted < 65_536 ? shifted : target + 1
        return PortProbe.nextFree(from: candidate) ?? candidate
    }

    func startLANIfWanted() {
        guard service.lanExposed, proxy == nil else { return }
        guard let target = service.activePort ?? service.detectedURL?.port else {
            appendSystem("LAN: no port known yet — nothing to relay.")
            return
        }
        // Prefer the port this service used last so links stay stable, but never insist on
        // it: something may have taken it while the service was stopped. Ask for it and
        // fall back — a working relay on a different port beats a stable port that fails.
        var listen = service.lanPort ?? Self.defaultLANPort(for: target)

        // Wired before start(), so a listener that dies during startup is still reported.
        let makeProxy: (Int) -> LANProxy = { [weak self] port in
            let proxy = LANProxy(listenPort: port, targetPort: target)
            proxy.onFailure = { error in
                self?.appendSystem("LAN relay stopped: \(error.localizedDescription)")
                DispatchQueue.main.async { self?.service.lanURL = nil }
            }
            return proxy
        }

        var proxy = makeProxy(listen)
        do {
            try proxy.start()
        } catch {
            guard let fallback = PortProbe.nextFree(from: listen + 1), fallback != listen else {
                appendSystem("LAN relay failed: \(error.localizedDescription)")
                return
            }
            appendSystem("LAN: port \(listen) wouldn't bind — using \(fallback) instead.")
            listen = fallback
            proxy = makeProxy(listen)
            do {
                try proxy.start()
            } catch {
                appendSystem("LAN relay failed: \(error.localizedDescription)")
                return
            }
        }
        self.proxy = proxy

        let addresses = PortProbe.lanAddresses()
        let bonjour = LANPresence.localHostname
        DispatchQueue.main.async {
            self.service.lanPort = listen
            self.service.lanURL = URL(string: "http://\(bonjour):\(listen)")
            // The relay listens on every interface even when the server behind it doesn't,
            // so from the network's point of view this service is now reachable.
            self.service.lanBinding = .allInterfaces
            self.advertiser.advertise(name: self.service.name, port: listen)
        }
        appendSystem("LAN relay up on :\(listen) → localhost:\(target)")
        appendSystem("  http://\(bonjour):\(listen)  (Bonjour)")
        for address in addresses {
            appendSystem("  http://\(address.ip):\(listen)  (\(address.label))")
        }
        appendSystem("Anyone on this network can reach it — there's no authentication in front.")
    }

    func stopLAN() {
        guard proxy != nil else { return }
        proxy?.stop()
        proxy = nil
        appendSystem("LAN relay stopped.")
        DispatchQueue.main.async {
            self.service.lanURL = nil
            self.advertiser.stop()
            // Re-check the server's own binding: without the relay it may be loopback-only.
            self.service.lanBinding = .unknown
            if self.service.state.isActive { self.scheduleLANCheck() }
        }
    }

    // MARK: - Output handling

    private func handleData(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }   // EOF
        ioQueue.async { [weak self] in
            guard let self else { return }
            var buffer = isError ? self.stderrRemainder + data : self.stdoutRemainder + data
            var producedLines: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let raw = String(decoding: lineData, as: UTF8.self)
                producedLines.append(OutputParser.stripANSI(raw)
                    .replacingOccurrences(of: "\r", with: ""))
            }
            if isError { self.stderrRemainder = buffer } else { self.stdoutRemainder = buffer }
            if producedLines.isEmpty { return }
            self.emit(producedLines, isError: isError)
        }
    }

    /// `isSystem` marks Thunderbox's own `»` notes. They must never reach the parsers:
    /// several of them talk *about* ports ("LAN relay failed: Port 15173 is already in
    /// use"), and scanning them makes the app read its own commentary back as if the
    /// service had reported a conflict.
    private func emit(_ texts: [String], isError: Bool, isSystem: Bool = false) {
        // URL and conflict detection off the main thread.
        var foundURL: URL?
        if !urlLocked, !isSystem {
            for t in texts { if let u = OutputParser.detectURL(in: t) { foundURL = u; break } }
        }
        let conflict = isSystem ? nil : scanForConflict(texts)

        let now = Date()
        var newLines: [LogLine] = []
        for t in texts {
            lineCounter &+= 1
            newLines.append(LogLine(id: lineCounter, text: t, isError: isError, date: now))
        }
        DispatchQueue.main.async {
            self.lines.append(contentsOf: newLines)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
            if let u = foundURL, self.service.isServer {
                self.service.detectedURL = u
                self.urlLocked = true
                if let p = u.port { self.service.activePort = p }
                self.scheduleLANCheck()
            }
            if let conflict { self.service.conflict = self.merged(conflict) }
        }
    }

    /// Read a port collision out of the service's own words. Catches what the preflight
    /// can't: a port we never parsed from the command. Tools that print the override to
    /// use (`… with BOOK_READER_PORT=4322`) hand over the entire remedy.
    private func scanForConflict(_ texts: [String]) -> PortConflict? {
        var result: PortConflict?
        for text in texts {
            let (isConflict, port) = OutputParser.detectPortConflict(in: text)
            if isConflict {
                watchingForPortVar = true
                result = PortConflict(port: port ?? service.effectivePort ?? 0, holder: nil)
            }
            if watchingForPortVar, let hint = OutputParser.detectPortVar(in: text) {
                var conflict = result
                    ?? PortConflict(port: service.effectivePort ?? 0, holder: nil)
                conflict.suggestedVar = hint.name
                conflict.suggestedPort = hint.port ?? conflict.suggestedPort
                result = conflict
            }
        }
        return result
    }

    /// Keep whatever the preflight already learned (the holding process, the sibling
    /// service) while layering on what the output revealed.
    private func merged(_ incoming: PortConflict) -> PortConflict {
        guard let existing = service.conflict else { return incoming }
        var result = existing
        result.suggestedVar = incoming.suggestedVar ?? existing.suggestedVar
        result.suggestedPort = incoming.suggestedPort ?? existing.suggestedPort
        return result
    }

    private func appendSystem(_ text: String) {
        ioQueue.async { [weak self] in
            self?.emit(["» " + text], isError: false, isSystem: true)
        }
    }

    // MARK: - Termination

    private func handleTermination(_ p: Process) {
        let status = p.terminationStatus
        let bySignal = p.terminationReason == .uncaughtSignal
        stopRamTimer()
        stopLAN()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        DispatchQueue.main.async {
            self.advertiser.stop()
            self.service.lanBinding = .unknown
            self.service.pid = nil
            self.service.memoryMB = nil
            if self.intentionalStop {
                self.service.state = .stopped
                self.appendSystem("Stopped.")
            } else if status == 0 && !bySignal {
                self.service.state = .stopped
                self.appendSystem("Exited cleanly (code 0).")
            } else if self.service.conflict != nil {
                // The exit code is real, but "port in use" says far more than "exit 1".
                self.service.state = .blocked
                self.appendSystem("FAILED — \(bySignal ? "killed by signal" : "exit code") \(status).")
            } else {
                self.service.state = .failed(code: status)
                self.appendSystem("FAILED — \(bySignal ? "killed by signal" : "exit code") \(status).")
            }
            self.process = nil
        }
    }

    private func setState(_ s: RunState) {
        DispatchQueue.main.async { self.service.state = s }
    }

    // MARK: - LAN presence

    /// Once we believe a server URL exists, find out whether the socket is actually
    /// reachable from other devices (0.0.0.0) or loopback-only, and — when it is
    /// reachable — broadcast it over Bonjour so the rest of the network can see it.
    /// Retries a couple of times because the banner often prints before the bind.
    private func scheduleLANCheck(attempt: Int = 0) {
        guard service.isServer, let url = service.detectedURL else { return }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let delay: Double = attempt == 0 ? 1.0 : 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.service.state.isActive else { return }
            LANPresence.checkBinding(port: port) { [weak self] binding in
                guard let self, self.service.state.isActive else { return }
                self.service.lanBinding = binding
                switch binding {
                case .allInterfaces:
                    self.advertiser.advertise(name: self.service.name, port: port)
                case .localhostOnly:
                    self.advertiser.stop()
                case .unknown:
                    if attempt < 2 { self.scheduleLANCheck(attempt: attempt + 1) }
                }
            }
        }
    }

    // MARK: - RAM sampling

    private func startRamTimer(pid: Int32) {
        stopRamTimer()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sampleRam(pid: pid)
        }
        RunLoop.main.add(timer, forMode: .common)
        ramTimer = timer
        sampleRam(pid: pid)
    }

    private func stopRamTimer() {
        ramTimer?.invalidate()
        ramTimer = nil
    }

    /// Sum RSS (KB) of every process in the service's process group → MB.
    private func sampleRam(pid: Int32) {
        ioQueue.async { [weak self] in
            guard let self, self.process?.isRunning == true else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-o", "rss=", "-g", "\(pid)"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            let totalKB = text.split(whereSeparator: { $0 == "\n" || $0 == " " })
                .compactMap { Int($0) }.reduce(0, +)
            guard totalKB > 0 else { return }
            let mb = Double(totalKB) / 1024.0
            DispatchQueue.main.async {
                if self.service.state.isActive { self.service.memoryMB = mb }
            }
        }
    }

    // MARK: - Helpers

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
