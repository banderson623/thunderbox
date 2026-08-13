import XCTest
@testable import Thunderbox

final class ScriptScannerTests: XCTestCase {

    // MARK: - Server heuristic

    func testDevServersScoreAsServers() {
        XCTAssertGreaterThanOrEqual(ScriptScanner.serverScore(command: "vite", name: "dev"), 3)
        XCTAssertGreaterThanOrEqual(ScriptScanner.serverScore(command: "next dev", name: "dev"), 3)
        XCTAssertGreaterThanOrEqual(
            ScriptScanner.serverScore(command: "uvicorn app:api --port 8000", name: "api"), 3)
        XCTAssertGreaterThanOrEqual(
            ScriptScanner.serverScore(command: "tsx src/server/index.ts", name: "serve"), 3)
    }

    func testBuildScriptsAreSuppressed() {
        XCTAssertEqual(ScriptScanner.serverScore(command: "vite build", name: "build"), 0)
        XCTAssertEqual(ScriptScanner.serverScore(command: "eslint src --fix", name: "lint"), 0)
        XCTAssertEqual(ScriptScanner.serverScore(command: "jest --coverage", name: "test"), 0)
    }

    func testBuildSuppressionYieldsToStrongServerSignal() {
        // A script that builds AND serves is still a server.
        XCTAssertGreaterThanOrEqual(
            ScriptScanner.serverScore(command: "tsc && nodemon dist/index.js", name: "start"), 3)
    }

    func testPlainUtilityScoresLow() {
        XCTAssertLessThan(ScriptScanner.serverScore(command: "echo hello", name: "greet"), 3)
    }

    // MARK: - Port parsing

    func testParsesLongFlag() {
        XCTAssertEqual(ScriptScanner.parsePort(in: "vite --port 5173"), 5173)
        XCTAssertEqual(ScriptScanner.parsePort(in: "serve --port=8080 ."), 8080)
    }

    func testParsesShortFlagAndEnvStyle() {
        XCTAssertEqual(ScriptScanner.parsePort(in: "http-server -p 9090"), 9090)
        XCTAssertEqual(ScriptScanner.parsePort(in: "PORT=3000 node server.js"), 3000)
    }

    func testParsesLocalhostURL() {
        XCTAssertEqual(ScriptScanner.parsePort(in: "open http://localhost:4321"), 4321)
    }

    func testRejectsOutOfRangePort() {
        XCTAssertNil(ScriptScanner.parsePort(in: "connect :99999"))
    }

    func testNoPortReturnsNil() {
        XCTAssertNil(ScriptScanner.parsePort(in: "npm run dev"))
    }

    // MARK: - Folder scan (integration, on a temp fixture tree)

    func testScanFindsNpmShellAndPythonServers() throws {
        let root = try makeFixtureProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let candidates = ScriptScanner.scan(folder: root.path)
        let byCommand = Dictionary(grouping: candidates, by: \.command)

        XCTAssertNotNil(byCommand["npm run dev"], "npm dev script should be found")
        XCTAssertNotNil(byCommand["./run.sh"], "executable shell script should be found")
        XCTAssertNotNil(byCommand["python3 scripts/serve.py"],
                        "python server should be found with repo-relative path")
        // The CLI-ish python file must NOT appear — only server-looking python is surfaced.
        XCTAssertFalse(candidates.contains { $0.command.contains("tool.py") })
        // node_modules must be pruned.
        XCTAssertFalse(candidates.contains { $0.folder.contains("node_modules") })
        // Servers sort first.
        if let first = candidates.first {
            XCTAssertTrue(first.isServer, "servers should sort to the top")
        }
    }

    private func makeFixtureProject() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("thunderbox-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("scripts"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/junk"),
                               withIntermediateDirectories: true)

        try #"{"name":"fixture","scripts":{"dev":"vite","build":"vite build"}}"#
            .write(to: root.appendingPathComponent("package.json"),
                   atomically: true, encoding: .utf8)

        let sh = root.appendingPathComponent("run.sh")
        try "#!/bin/bash\nnpm run dev\n".write(to: sh, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)

        try """
        from http.server import HTTPServer, SimpleHTTPRequestHandler
        if __name__ == "__main__":
            HTTPServer(("", 4321), SimpleHTTPRequestHandler).serve_forever()
        """.write(to: root.appendingPathComponent("scripts/serve.py"),
                  atomically: true, encoding: .utf8)

        try "import sys\nprint(sys.argv)\n"
            .write(to: root.appendingPathComponent("scripts/tool.py"),
                   atomically: true, encoding: .utf8)

        // A decoy package.json inside node_modules that must be pruned.
        try #"{"name":"junk","scripts":{"dev":"vite"}}"#
            .write(to: root.appendingPathComponent("node_modules/junk/package.json"),
                   atomically: true, encoding: .utf8)
        return root
    }
}
