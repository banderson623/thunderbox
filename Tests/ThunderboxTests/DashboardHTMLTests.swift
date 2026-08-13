import XCTest
@testable import Thunderbox

/// The phone dashboard's markup. Tapping a service has to open it *and* leave the
/// dashboard where it was — installed to the home screen there's no browser chrome to
/// go back with.
@MainActor
final class DashboardHTMLTests: XCTestCase {

    private func entry(name: String, lanURL: URL?, active: Bool = true,
                       localhostOnly: Bool = false) -> DashboardEntry {
        DashboardEntry(name: name, command: "npm run dev", stateLabel: "Running",
                       isActive: active, isFailed: false, isServer: true,
                       lanURL: lanURL, localhostOnly: localhostOnly, memoryMB: 514)
    }

    func testReachableServiceOpensInANewTab() throws {
        let url = try XCTUnwrap(URL(string: "http://brians-macbook-pro-m3.local:15173/"))
        let html = DashboardServer.renderHTML(entries: [entry(name: "Books", lanURL: url)])

        let anchor = try XCTUnwrap(
            html.split(separator: "\n").first { $0.contains("<a class=\"card") })
        XCTAssertTrue(anchor.contains("target=\"_blank\""), anchor.description)
        XCTAssertTrue(anchor.contains("rel=\"noopener\""), anchor.description)
        XCTAssertTrue(anchor.contains("href=\"http://brians-macbook-pro-m3.local:15173/\""))
    }

    func testUnreachableServiceIsNotALink() {
        let html = DashboardServer.renderHTML(
            entries: [entry(name: "soc2", lanURL: nil, localhostOnly: true)])
        XCTAssertFalse(html.contains("<a class=\"card"))
        XCTAssertTrue(html.contains("Mac only"))
    }

    /// A running server with no reachable address and no explanation is a dead card —
    /// which is what "Books" looked like before the relay's URL reached the dashboard.
    func testRunningServiceAlwaysSaysSomething() {
        let html = DashboardServer.renderHTML(entries: [entry(name: "Books", lanURL: nil)])
        XCTAssertTrue(html.contains("<a class=\"card") || html.contains("class=\"tag\""),
                      "a running service must be either openable or explained")
    }

    func testNameIsHTMLEscaped() {
        let html = DashboardServer.renderHTML(
            entries: [entry(name: "<script>x</script>", lanURL: nil)])
        XCTAssertFalse(html.contains("<script>x"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }
}
