import XCTest
@testable import Thunderbox

final class OutputParserTests: XCTestCase {

    // MARK: - ANSI stripping

    func testStripPlainTextUntouched() {
        XCTAssertEqual(OutputParser.stripANSI("hello world"), "hello world")
    }

    func testStripCSIColorCodes() {
        XCTAssertEqual(OutputParser.stripANSI("\u{1B}[31mred\u{1B}[0m plain"), "red plain")
        XCTAssertEqual(OutputParser.stripANSI("\u{1B}[1;32;40mbold green\u{1B}[m"), "bold green")
    }

    func testStripOSCTitleSequence() {
        XCTAssertEqual(OutputParser.stripANSI("\u{1B}]0;my title\u{07}after"), "after")
        XCTAssertEqual(OutputParser.stripANSI("\u{1B}]8;;http://x\u{1B}\\link"), "link")
    }

    func testStripSimpleTwoCharEscape() {
        XCTAssertEqual(OutputParser.stripANSI("\u{1B}Mline"), "line")
    }

    // MARK: - URL detection

    func testDetectsLocalhostURL() {
        XCTAssertEqual(
            OutputParser.detectURL(in: "book-reader on http://localhost:4321")?.absoluteString,
            "http://localhost:4321")
    }

    func testNormalizesZeroHostToLocalhost() {
        XCTAssertEqual(
            OutputParser.detectURL(in: "Serving at http://0.0.0.0:8000/")?.absoluteString,
            "http://localhost:8000/")
    }

    func testTrimsTrailingPunctuation() {
        XCTAssertEqual(
            OutputParser.detectURL(in: "ready (http://127.0.0.1:5173).")?.absoluteString,
            "http://127.0.0.1:5173")
    }

    func testDetectsURLBehindANSIColor() {
        let line = "\u{1B}[32m➜ Local: http://localhost:5173/\u{1B}[0m"
        XCTAssertEqual(OutputParser.detectURL(in: line)?.absoluteString,
                       "http://localhost:5173/")
    }

    func testDetectsPortPhrase() {
        XCTAssertEqual(
            OutputParser.detectURL(in: "Listening on port 8777")?.absoluteString,
            "http://localhost:8777")
    }

    func testIgnoresNonLocalURLs() {
        XCTAssertNil(OutputParser.detectURL(in: "see https://example.com/docs"))
    }

    func testIgnoresPlainChatter() {
        XCTAssertNil(OutputParser.detectURL(in: "compiled 42 modules in 1.3s"))
    }
}
