import Foundation

/// Discovers runnable candidates in a folder and scores whether each starts a web server.
enum ScriptScanner {

    private static let skipDirs: Set<String> = [
        "node_modules", ".git", "dist", "build", ".next", ".nuxt", ".venv",
        "venv", "__pycache__", "vendor", ".cache", "coverage", "lib", "out",
        ".svelte-kit", "target", ".idea", ".vscode", "tmp"
    ]

    // MARK: - Public entry

    /// Scan `root` (and its immediate subdirectories) for npm scripts and shell scripts.
    static func scan(folder root: String) -> [ScriptCandidate] {
        let fm = FileManager.default
        var candidates: [ScriptCandidate] = []
        var dirs = [root]
        if let children = try? fm.contentsOfDirectory(atPath: root) {
            for child in children {
                if skipDirs.contains(child) || child.hasPrefix(".") { continue }
                let full = (root as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    dirs.append(full)
                }
            }
        }

        for dir in dirs {
            candidates.append(contentsOf: npmCandidates(in: dir))
            candidates.append(contentsOf: shellCandidates(in: dir))
            candidates.append(contentsOf: pythonCandidates(in: dir, root: root))
        }

        // Servers first (highest score), then alphabetical.
        candidates.sort {
            if $0.isServer != $1.isServer { return $0.isServer && !$1.isServer }
            if $0.serverScore != $1.serverScore { return $0.serverScore > $1.serverScore }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return candidates
    }

    // MARK: - npm

    private static func npmCandidates(in dir: String) -> [ScriptCandidate] {
        let pkgPath = (dir as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: pkgPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = obj["scripts"] as? [String: String], !scripts.isEmpty
        else { return [] }

        let pkgName = (obj["name"] as? String) ?? (dir as NSString).lastPathComponent

        return scripts.keys.sorted().map { key -> ScriptCandidate in
            let raw = scripts[key] ?? ""
            // Follow run-p/run-s/npm-run-all/npm:foo references to judge server-ness.
            let resolved = resolveNpmText(scriptName: key, scripts: scripts, visited: [])
            let score = serverScore(command: resolved, name: key)
            let port = parsePort(in: resolved)
            return ScriptCandidate(
                name: "\(pkgName): \(key)",
                folder: dir,
                command: "npm run \(key)",
                kind: .npm,
                isServer: score >= 3,
                serverScore: score,
                declaredPort: port,
                detail: raw)
        }
    }

    /// Concatenate a script's command with the commands of scripts it references (1+ levels).
    private static func resolveNpmText(scriptName: String, scripts: [String: String],
                                       visited: Set<String>) -> String {
        guard !visited.contains(scriptName), let cmd = scripts[scriptName] else { return "" }
        var seen = visited
        seen.insert(scriptName)
        var text = cmd

        for token in referencedScriptNames(in: cmd, keys: Set(scripts.keys)) {
            text += " " + resolveNpmText(scriptName: token, scripts: scripts, visited: seen)
        }
        return text
    }

    /// Find words in a command that name sibling scripts (run-s/run-p/npm-run-all/npm:foo/foo:*).
    private static func referencedScriptNames(in cmd: String, keys: Set<String>) -> Set<String> {
        var result: Set<String> = []
        let separators = CharacterSet(charactersIn: " \t\"'`&|<>()")
        for rawWord in cmd.components(separatedBy: separators) where !rawWord.isEmpty {
            var word = rawWord
            if word.hasPrefix("npm:") { word.removeFirst(4) }        // concurrently "npm:dev"
            if word == "run" || word == "npm" || word == "run-s" || word == "run-p" { continue }
            // Wildcard like "lint:*" or "build:*"
            if word.hasSuffix(":*") || word.hasSuffix("*") {
                let prefix = String(word.dropLast(word.hasSuffix(":*") ? 2 : 1))
                for k in keys where k.hasPrefix(prefix) { result.insert(k) }
                continue
            }
            if keys.contains(word) { result.insert(word) }
        }
        return result
    }

    // MARK: - Shell scripts

    private static func shellCandidates(in dir: String) -> [ScriptCandidate] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [ScriptCandidate] = []
        for child in children where child.hasSuffix(".sh") {
            let full = (dir as NSString).appendingPathComponent(child)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            let contents = (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""
            let score = serverScore(command: contents, name: child)
            let port = parsePort(in: contents)
            let executable = fm.isExecutableFile(atPath: full)
            let command = executable ? "./\(child)" : "bash \(child)"
            let firstLine = contents.split(separator: "\n").first.map(String.init) ?? ""
            out.append(ScriptCandidate(
                name: child,
                folder: dir,
                command: command,
                kind: .shell,
                isServer: score >= 3,
                serverScore: score,
                declaredPort: port,
                detail: firstLine.isEmpty ? command : firstLine))
        }
        return out
    }

    // MARK: - Python scripts

    /// Discover `*.py` files that *look like a web server*. Unlike npm/shell, we only surface
    /// server-scoring Python files — a project's utility scripts (CLIs) shouldn't flood the
    /// list. Run from the scanned root using a repo-root-relative path (`python3 scripts/x.py`).
    private static func pythonCandidates(in dir: String, root: String) -> [ScriptCandidate] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [ScriptCandidate] = []
        for child in children where child.hasSuffix(".py") {
            if child.hasPrefix("__") || child.hasPrefix(".") { continue }   // __init__.py, etc.
            let full = (dir as NSString).appendingPathComponent(child)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard let contents = try? String(contentsOfFile: full, encoding: .utf8) else { continue }

            guard let (score, runner) = pythonServerScore(contents: contents) else { continue }

            let rel = relativePath(of: full, from: root)
            let command = runner.isEmpty ? "python3 \(rel)" : "\(runner) \(rel)"
            out.append(ScriptCandidate(
                name: rel,
                folder: root,
                command: command,
                kind: .python,
                isServer: true,
                serverScore: score,
                declaredPort: parsePort(in: contents),
                detail: command))
        }
        return out
    }

    /// Returns (score, runnerCommand) if the file looks like a runnable web server, else nil.
    /// `runnerCommand` is "" for self-starting scripts (run with `python3`), or e.g.
    /// "streamlit run" for files launched by an external runner.
    private static func pythonServerScore(contents: String) -> (Int, String)? {
        let lower = contents.lowercased()

        // A launch call (serve_forever/app.run/uvicorn.run/…) is the primary signal.
        let hasLaunch = pythonLaunchTokens.contains { lower.contains($0) }
        // …or an import of a framework whose files are started by an external runner.
        let runner = pythonRunnerImports.first { lower.contains($0.needle) }?.run

        guard hasLaunch || runner != nil else { return nil }

        var score = 6
        if parsePort(in: contents) != nil { score += 3 }
        if lower.contains("__main__") { score += 2 }
        if pythonFrameworks.contains(where: { lower.contains($0) }) { score += 1 }
        return (score, runner ?? "")
    }

    private static func relativePath(of full: String, from root: String) -> String {
        if full.hasPrefix(root + "/") { return String(full.dropFirst(root.count + 1)) }
        return (full as NSString).lastPathComponent
    }

    // MARK: - Server heuristic

    /// Unambiguous "start a long-running listener" tokens (each adds 6).
    private static let strongTokens = [
        "webpack serve", "webpack-dev-server", "webpack-dashboard", "next dev",
        "next start", "nuxt dev", "astro dev", "remix dev", "gatsby develop",
        "nodemon", "ts-node-dev", "tsx watch", "flask run", "uvicorn", "gunicorn",
        "rails server", "rails s ", "http-server", "live-server", "php -s",
        "http.server", "ng serve", "wrangler dev", "streamlit run", "vite preview",
        "vite serve", "vite dev", "serve -", "serve site", "serve ."
    ]

    /// Python files are servers only if they actually *start* one. These are launch calls,
    /// not mere framework imports — that's what separates a server from a library module.
    private static let pythonLaunchTokens = [
        "serve_forever", "app.run(", ".run(host", "run(host=", "uvicorn.run",
        "app.listen", "web.run_app", "make_server(", "run_server(", "httpserver(",
        "threadinghttpserver(", "waitress.serve", "hypercorn", "runserver",
        "socketserver.", "run_simple(", "app.run_server(", "serve(app"
    ]
    /// Frameworks that are launched by an external runner (`streamlit run x.py`) rather than
    /// by a call inside the file. Presence of the import means the file *is* the server.
    private static let pythonRunnerImports: [(needle: String, run: String)] = [
        ("import streamlit", "streamlit run"),
        ("streamlit as st", "streamlit run")
    ]
    private static let pythonFrameworks = [
        "flask", "fastapi", "django", "bottle", "tornado", "aiohttp", "gradio",
        "dash", "sanic", "quart", "starlette", "cherrypy"
    ]
    private static let mediumTokens = [
        "concurrently", "--port", "-p ", "port=", " listen", "localhost",
        "0.0.0.0", "wait-port", "wait-on"
    ]
    /// Signals the script's job is to build/test/lint/typecheck, not to serve.
    private static let buildTokens = [
        "vite build", "webpack --", "tsc ", "tsc -", "tsc\"", "babel ", "rollup",
        "esbuild", "eslint", "jest", "cypress run", "rimraf", "gherkin-lint",
        "check-engine", " clean", "npm-run-all --print-label clean"
    ]
    private static let nameTokens = ["dev", "start", "serve", "develop", "preview"]

    static func serverScore(command: String, name: String) -> Int {
        let cmd = command.lowercased()
        let nm = name.lowercased()
        var score = 0
        var hasStrong = false

        for t in strongTokens where cmd.contains(t) { score += 6; hasStrong = true }

        // "vite" bare (no subcommand) = dev server; "vite build" is a build (handled below).
        if cmd.contains("vite") && !cmd.contains("vite build") && !cmd.contains("vite preview") {
            score += 6; hasStrong = true
        }
        // A JS/TS runtime pointed at a `…server…` entrypoint is likely a server
        // (e.g. `tsx src/server/index.ts`, `node dist/server/index.js`).
        let runtimes = ["node ", "babel-node", "tsx ", "ts-node", "bun ", "deno run"]
        if runtimes.contains(where: { cmd.contains($0) }) && cmd.contains("server") {
            score += 4
        }

        for t in mediumTokens where cmd.contains(t) { score += 3 }

        // name-based: exact name or "prefix:dev" / "dev:*" style
        let baseName = (nm as NSString).lastPathComponent
            .replacingOccurrences(of: ".sh", with: "")
        for t in nameTokens {
            if baseName == t || baseName.hasSuffix(":\(t)") || baseName.hasPrefix("\(t):") {
                score += 2
            }
        }

        // Suppress build/test/lint scripts unless they also clearly start a server
        // (e.g. `run-p build watch-server`).
        let looksBuildish = buildTokens.contains { cmd.contains($0) }
        if looksBuildish && !hasStrong { return 0 }

        return score
    }

    // MARK: - Port parsing

    static func parsePort(in command: String) -> Int? {
        let patterns = [
            #"--port[=\s]+(\d{2,5})"#,
            #"-p[=\s]+(\d{2,5})"#,
            #"PORT[=\s]+(\d{2,5})"#,
            #"port.{0,40}?default[=\s]*(\d{2,5})"#,   // argparse: --port … default=8777
            #"localhost:(\d{2,5})"#,
            #":(\d{2,5})\b"#
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive])
            else { continue }
            let range = NSRange(command.startIndex..., in: command)
            if let m = re.firstMatch(in: command, range: range), m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: command), let port = Int(command[r]),
               port > 0, port < 65536 {
                return port
            }
        }
        return nil
    }
}
