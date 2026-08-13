import Foundation

/// An environment variable that plausibly controls this project's port.
struct PortVarCandidate: Identifiable, Equatable {
    let name: String
    /// Where it was found — shown so the user can judge the guess.
    let source: String
    /// A default value seen alongside it, if any.
    let defaultValue: Int?
    var id: String { name }
}

/// Works out which env var moves a project's port.
///
/// There is no universal answer. `PORT` is the de-facto standard and a large share of the
/// Node/Ruby world honours it, but plenty of projects pick their own name to avoid
/// colliding with an exported `PORT` in the shell — which is a reasonable choice that
/// costs discoverability. So rather than guess, look at the project: its `.env` files
/// name the variables outright, and its source reads them by name.
enum PortVarFinder {

    /// Best guesses first: declared in an env file, then read in source, then whatever
    /// the framework is known to honour.
    static func candidates(folder: String, command: String) -> [PortVarCandidate] {
        var seen = Set<String>()
        var out: [PortVarCandidate] = []

        func add(_ c: PortVarCandidate) {
            guard !seen.contains(c.name) else { return }
            seen.insert(c.name)
            out.append(c)
        }

        for c in fromEnvFiles(folder: folder) { add(c) }
        for c in fromSource(folder: folder) { add(c) }
        for c in fromFrameworkTable(command: command) { add(c) }
        add(PortVarCandidate(name: "PORT", source: "conventional default", defaultValue: nil))
        return out
    }

    // MARK: - .env files

    private static let envFileNames = [
        ".env.example", ".env.sample", ".env.template", ".env", ".env.local", ".env.development"
    ]

    private static func fromEnvFiles(folder: String) -> [PortVarCandidate] {
        var out: [PortVarCandidate] = []
        for file in envFileNames {
            let path = (folder as NSString).appendingPathComponent(file)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[trimmed.startIndex..<eq])
                    .trimmingCharacters(in: .whitespaces)
                guard isPortVarName(key) else { continue }
                let value = String(trimmed[trimmed.index(after: eq)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                out.append(PortVarCandidate(name: key, source: file, defaultValue: Int(value)))
            }
        }
        return out
    }

    // MARK: - Source

    /// `process.env.FOO_PORT`, `process.env["FOO_PORT"]`, `os.environ["FOO_PORT"]`,
    /// `os.getenv("FOO_PORT")`, `ENV["FOO_PORT"]`.
    /// The lookahead requires PORT somewhere in the name while letting the capture be a
    /// plain token, so bare `process.env.PORT` matches as readily as `FOO_PORT`.
    private static let envReadRegex = try! NSRegularExpression(
        pattern: #"(?:process\.env|os\.environ|os\.getenv|ENV|Environment)\s*[\.\(\[]\s*["']?(?=[A-Z0-9_]*PORT)([A-Z][A-Z0-9_]*)["']?"#)

    private static let skipDirs: Set<String> = [
        "node_modules", ".git", "dist", "build", ".next", ".venv", "venv",
        "__pycache__", "vendor", "target", ".build", "coverage"
    ]
    private static let sourceExtensions: Set<String> = [
        "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "rb", "go", "sh", "json", "yml", "yaml"
    ]

    private static func fromSource(folder: String) -> [PortVarCandidate] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: folder, isDirectory: true),
                                         includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        var out: [PortVarCandidate] = []
        var examined = 0

        for case let url as URL in walker {
            if skipDirs.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard sourceExtensions.contains(url.pathExtension) else { continue }
            examined += 1
            if examined > 500 { break }   // keep an add-time scan snappy on big repos

            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count < 512 * 1024,
                  let text = String(data: data, encoding: .utf8) else { continue }

            let range = NSRange(text.startIndex..., in: text)
            for m in envReadRegex.matches(in: text, range: range) {
                guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { continue }
                let relative = url.path.hasPrefix(folder)
                    ? String(url.path.dropFirst(folder.count).drop(while: { $0 == "/" }))
                    : url.lastPathComponent
                out.append(PortVarCandidate(name: String(text[r]),
                                            source: relative,
                                            defaultValue: nearbyDefault(in: text, after: m.range)))
            }
        }
        return out
    }

    /// `process.env.FOO_PORT ?? 4321` / `os.getenv("FOO_PORT", 8000)` — the literal right
    /// after the read is almost always the fallback port.
    private static let fallbackRegex = try! NSRegularExpression(
        pattern: #"^["'\]\)\s]*(?:\?\?|\|\||,|or)\s*["']?(\d{2,5})"#)

    private static func nearbyDefault(in text: String, after range: NSRange) -> Int? {
        let start = range.location + range.length
        guard start < (text as NSString).length else { return nil }
        let tail = NSRange(location: start, length: min(40, (text as NSString).length - start))
        guard let m = fallbackRegex.firstMatch(in: text, range: tail), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    // MARK: - Framework defaults

    /// Tools that ignore `PORT` and want their own variable.
    private static let frameworkVars: [(needle: String, name: String)] = [
        ("streamlit", "STREAMLIT_SERVER_PORT"),
        ("uvicorn", "UVICORN_PORT"),
        ("flask", "FLASK_RUN_PORT"),
        ("jupyter", "JUPYTER_PORT"),
        ("nuxt", "NUXT_PORT"),
        ("gunicorn", "GUNICORN_PORT"),
    ]

    private static func fromFrameworkTable(command: String) -> [PortVarCandidate] {
        let lower = command.lowercased()
        return frameworkVars
            .filter { lower.contains($0.needle) }
            .map { PortVarCandidate(name: $0.name, source: "\($0.needle) default", defaultValue: nil) }
    }

    // MARK: - Helpers

    static func isPortVarName(_ s: String) -> Bool {
        guard s.contains("PORT") else { return false }
        return s.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }
}
