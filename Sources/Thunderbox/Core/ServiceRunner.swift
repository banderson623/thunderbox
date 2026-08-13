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
    // Strong on purpose: async work (termination handler, kill watchdog) can outlive the
    // service's removal from the store, and Service never points back at its runner, so
    // there is no cycle. `unowned` here would dangle and crash on remove-while-running.
    let service: Service

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
    private var pendingRestart = false
    private var urlLocked = false

    private let ioQueue = DispatchQueue(label: "thunderbox.io", qos: .utility)

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
        // Remainder buffers belong to ioQueue; reset them there, not on the main thread.
        ioQueue.async { [weak self] in
            self?.stdoutRemainder = Data()
            self?.stderrRemainder = Data()
        }

        appendSystem("$ (cd \(service.displayFolder)) \(service.command)")

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
        proc.environment = env

        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil }   // EOF: stop the callbacks
            self?.handleData(data, isError: false)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil }
            self?.handleData(data, isError: true)
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
            self.service.detectedURL = self.service.declaredPort.flatMap {
                URL(string: "http://localhost:\($0)")
            }
        }
        startRamTimer(pid: pid)
        // If it survives a moment, call it running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.process?.isRunning == true,
                  self.service.state == .starting else { return }
            self.service.state = .running
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else { return }
        intentionalStop = true
        let pid = proc.processIdentifier
        appendSystem("Stopping (SIGTERM → process group \(pid))…")
        // Signal the whole process group (negative pid).
        kill(-pid, SIGTERM)
        ioQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            // Check the process this watchdog was armed for — a restart may have already
            // replaced self.process with a fresh one that must not be killed (or blamed).
            guard let self, self.process === proc, proc.isRunning else { return }
            self.appendSystem("Still alive after 5s — SIGKILL.")
            kill(-pid, SIGKILL)
        }
    }

    func restart() {
        if process?.isRunning == true {
            // Relaunch as soon as the old process group is actually gone (see
            // handleTermination) instead of after a fixed worst-case delay.
            pendingRestart = true
            stop()
        } else {
            start()
        }
    }

    func clearLog() {
        DispatchQueue.main.async { self.lines.removeAll() }
    }

    // MARK: - Output handling

    private func handleData(_ data: Data, isError: Bool) {
        guard !data.isEmpty else {   // EOF: flush a trailing line that never got its \n
            ioQueue.async { [weak self] in
                guard let self else { return }
                let remainder = isError ? self.stderrRemainder : self.stdoutRemainder
                if isError { self.stderrRemainder = Data() } else { self.stdoutRemainder = Data() }
                guard !remainder.isEmpty else { return }
                let raw = String(decoding: remainder, as: UTF8.self)
                self.emit([OutputParser.stripANSI(raw).replacingOccurrences(of: "\r", with: "")],
                          isError: isError)
            }
            return
        }
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

    private func emit(_ texts: [String], isError: Bool) {
        // URL detection off the main thread.
        var foundURL: URL?
        if !urlLocked {
            for t in texts { if let u = OutputParser.detectURL(in: t) { foundURL = u; break } }
        }
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
            }
        }
    }

    private func appendSystem(_ text: String) {
        ioQueue.async { [weak self] in self?.emit(["» " + text], isError: false) }
    }

    // MARK: - Termination

    private func handleTermination(_ p: Process) {
        let status = p.terminationStatus
        let bySignal = p.terminationReason == .uncaughtSignal
        stopRamTimer()
        // Don't detach the pipe handlers here: output can still be in flight, and they
        // remove themselves on EOF (which closing the child's write ends guarantees).

        DispatchQueue.main.async {
            self.service.pid = nil
            self.service.memoryMB = nil
            if self.intentionalStop {
                self.service.state = .stopped
                self.appendSystem("Stopped.")
            } else if status == 0 && !bySignal {
                self.service.state = .stopped
                self.appendSystem("Exited cleanly (code 0).")
            } else {
                self.service.state = .failed(code: status)
                self.appendSystem("FAILED — \(bySignal ? "killed by signal" : "exit code") \(status).")
            }
            self.process = nil
            if self.pendingRestart {
                self.pendingRestart = false
                self.start()
            }
        }
    }

    private func setState(_ s: RunState) {
        DispatchQueue.main.async { self.service.state = s }
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
