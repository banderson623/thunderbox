import XCTest
@testable import Thunderbox

/// The output-reading half of port-conflict handling: recognising the collision and
/// picking up the override the failing tool suggests.
final class PortConflictTests: XCTestCase {

    // MARK: - Recognising a conflict

    func testNodeEADDRINUSE() {
        let (isConflict, port) = OutputParser.detectPortConflict(
            in: "Error: listen EADDRINUSE: address already in use :::4321")
        XCTAssertTrue(isConflict)
        XCTAssertEqual(port, 4321)
    }

    func testNodeEADDRINUSEWithHost() {
        let (isConflict, port) = OutputParser.detectPortConflict(
            in: "listen EADDRINUSE: address already in use 127.0.0.1:3000")
        XCTAssertTrue(isConflict)
        XCTAssertEqual(port, 3000)
    }

    func testPythonOSError() {
        let (isConflict, _) = OutputParser.detectPortConflict(
            in: "OSError: [Errno 48] Address already in use")
        XCTAssertTrue(isConflict)
    }

    func testFriendlySentence() {
        let (isConflict, port) = OutputParser.detectPortConflict(
            in: "Port 4321 is already in use -- book-reader is probably already running.")
        XCTAssertTrue(isConflict)
        XCTAssertEqual(port, 4321)
    }

    /// Thunderbox's own `»` notes talk about ports too. They're kept away from the parsers
    /// by `emit(isSystem:)`, but the phrasing itself is worth pinning: this line looked
    /// exactly like a service reporting a collision, and the app believed itself.
    func testThunderboxsOwnRelayNoteLooksLikeAConflict() {
        let (isConflict, port) = OutputParser.detectPortConflict(
            in: "» LAN relay failed: Port 15173 is already in use on this Mac.")
        XCTAssertTrue(isConflict, "still matches — hence the isSystem guard in emit()")
        XCTAssertEqual(port, 15173)
    }

    func testOrdinaryOutputIsNotAConflict() {
        for line in ["Listening on port 4321", "  ➜  Local: http://localhost:5173/", ""] {
            XCTAssertFalse(OutputParser.detectPortConflict(in: line).isConflict, line)
        }
    }

    func testConflictSurvivesANSIColouring() {
        let (isConflict, port) = OutputParser.detectPortConflict(
            in: "\u{1B}[31mPort 8080 is already in use\u{1B}[0m")
        XCTAssertTrue(isConflict)
        XCTAssertEqual(port, 8080)
    }

    // MARK: - Reading the suggested override

    func testSuggestedVarWithValue() {
        let hint = OutputParser.detectPortVar(
            in: "Open http://localhost:4321, stop the other process, or start this one on another port with BOOK_READER_PORT=4322.")
        XCTAssertEqual(hint?.name, "BOOK_READER_PORT")
        XCTAssertEqual(hint?.port, 4322)
    }

    func testSuggestedVarWithoutValue() {
        let hint = OutputParser.detectPortVar(in: "Set PORT to choose a different port.")
        XCTAssertEqual(hint?.name, "PORT")
        XCTAssertNil(hint?.port)
    }

    func testFrameworkSpecificVar() {
        let hint = OutputParser.detectPortVar(in: "try STREAMLIT_SERVER_PORT=8502")
        XCTAssertEqual(hint?.name, "STREAMLIT_SERVER_PORT")
        XCTAssertEqual(hint?.port, 8502)
    }

    /// The prose word "Port" must not be mistaken for a variable named PORT.
    func testProseIsNotAVariable() {
        XCTAssertNil(OutputParser.detectPortVar(in: "Port 4321 is already in use."))
        XCTAssertNil(OutputParser.detectPortVar(in: "listening on the port"))
    }

    // MARK: - Variable-name recognition

    func testIsPortVarName() {
        XCTAssertTrue(PortVarFinder.isPortVarName("PORT"))
        XCTAssertTrue(PortVarFinder.isPortVarName("BOOK_READER_PORT"))
        XCTAssertTrue(PortVarFinder.isPortVarName("PORT_2"))
        XCTAssertFalse(PortVarFinder.isPortVarName("Port"))
        XCTAssertFalse(PortVarFinder.isPortVarName("DATABASE_URL"))
        XCTAssertFalse(PortVarFinder.isPortVarName("portNumber"))
    }

    // MARK: - Discovery from a project

    func testCandidatesPreferEnvFileOverConvention() throws {
        let dir = try makeTempProject([
            ".env.example": "# config\nBOOK_READER_PORT=4321\nDATABASE_URL=sqlite://x\n"
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = PortVarFinder.candidates(folder: dir.path, command: "npm run serve")
        XCTAssertEqual(found.first?.name, "BOOK_READER_PORT")
        XCTAssertEqual(found.first?.defaultValue, 4321)
        XCTAssertEqual(found.first?.source, ".env.example")
        XCTAssertFalse(found.contains { $0.name == "DATABASE_URL" })
    }

    func testCandidatesFromSourceReads() throws {
        let dir = try makeTempProject([
            "server.ts": "const port = Number(process.env.BOOK_READER_PORT ?? 4321)\n"
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = PortVarFinder.candidates(folder: dir.path, command: "tsx server.ts")
        let match = try XCTUnwrap(found.first { $0.name == "BOOK_READER_PORT" })
        XCTAssertEqual(match.defaultValue, 4321)
        XCTAssertEqual(match.source, "server.ts")
    }

    /// Bare `PORT` is the commonest name of all and must not fall through the pattern.
    func testCandidatesFromBarePortRead() throws {
        let dir = try makeTempProject([
            "index.js": "const port = process.env.PORT || 3000\n"
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = PortVarFinder.candidates(folder: dir.path, command: "node index.js")
        let match = try XCTUnwrap(found.first { $0.name == "PORT" })
        XCTAssertEqual(match.source, "index.js")
        XCTAssertEqual(match.defaultValue, 3000)
    }

    func testCandidatesFromPythonEnviron() throws {
        let dir = try makeTempProject([
            "app.py": "import os\nport = os.environ[\"APP_PORT\"]\n"
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = PortVarFinder.candidates(folder: dir.path, command: "python3 app.py")
        XCTAssertTrue(found.contains { $0.name == "APP_PORT" })
    }

    func testFrameworkFallbackAndConventionalDefault() throws {
        let dir = try makeTempProject([:])
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = PortVarFinder.candidates(folder: dir.path, command: "streamlit run app.py")
        XCTAssertEqual(found.map(\.name), ["STREAMLIT_SERVER_PORT", "PORT"])
    }

    func testNodeModulesIsNotScanned() throws {
        let dir = try makeTempProject([
            "node_modules/dep/index.js": "process.env.VENDOR_PORT\n"
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = PortVarFinder.candidates(folder: dir.path, command: "node index.js")
        XCTAssertFalse(found.contains { $0.name == "VENDOR_PORT" })
    }

    // MARK: - Port availability

    func testIsFreeReportsABoundPortAsTaken() throws {
        let listener = try TestListener()
        defer { listener.close() }
        XCTAssertFalse(PortProbe.isFree(listener.port))
        XCTAssertNotEqual(PortProbe.nextFree(from: listener.port), listener.port)
    }

    func testIsFreeRejectsOutOfRangePorts() {
        XCTAssertFalse(PortProbe.isFree(0))
        XCTAssertFalse(PortProbe.isFree(70_000))
    }

    // MARK: - LAN port defaults

    func testDefaultLANPortAvoidsTheServicePort() {
        let lan = ServiceRunner.defaultLANPort(for: 4321)
        XCTAssertNotEqual(lan, 4321)
        XCTAssertGreaterThanOrEqual(lan, 14_321)
    }

    func testDefaultLANPortStaysInRangeForHighPorts() {
        let lan = ServiceRunner.defaultLANPort(for: 60_000)
        XCTAssertLessThan(lan, 65_536)
        XCTAssertNotEqual(lan, 60_000)
    }

    // MARK: - Persistence

    /// Service lists written before env/LAN settings existed must still load.
    func testDecodesLegacyServiceJSON() throws {
        let legacy = """
        [{"id":"5FF3E8B0-1F4E-4E4C-9C7C-6E2E1B7A0001","name":"books",
          "folder":"/Users/x/Projects/books","command":"npm run serve",
          "kind":"npm","isServer":true,"declaredPort":4321}]
        """.data(using: .utf8)!

        let dtos = try JSONDecoder().decode([ServiceDTO].self, from: legacy)
        let dto = try XCTUnwrap(dtos.first)
        XCTAssertEqual(dto.name, "books")
        XCTAssertEqual(dto.declaredPort, 4321)
        XCTAssertEqual(dto.env, [:])
        XCTAssertNil(dto.portVar)
        XCTAssertFalse(dto.autoPort)
        XCTAssertFalse(dto.lanExposed)
    }

    func testConfiguredPortPrefersTheOverride() {
        let service = Service(name: "books", folder: "/tmp", command: "npm run serve",
                              kind: .npm, isServer: true, declaredPort: 4321)
        XCTAssertEqual(service.configuredPort, 4321)

        service.portVar = "BOOK_READER_PORT"
        service.env["BOOK_READER_PORT"] = "4322"
        XCTAssertEqual(service.configuredPort, 4322)
    }

    /// `activePort` describes the run that happened; it must not feed back into what the
    /// next launch asks for, or an automatic move would disagree with the real environment.
    func testActivePortShowsInTheUIButNotInTheNextLaunch() {
        let service = Service(name: "books", folder: "/tmp", command: "npm run serve",
                              kind: .npm, isServer: true, declaredPort: 4321)
        service.activePort = 4323

        XCTAssertEqual(service.effectivePort, 4323)
        XCTAssertEqual(service.configuredPort, 4321)
    }

    // MARK: - Helpers

    private func makeTempProject(_ files: [String: String]) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tbx-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }
}
