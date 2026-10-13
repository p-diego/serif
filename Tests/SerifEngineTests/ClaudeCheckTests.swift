import XCTest
import SerifCore
@testable import SerifEngine

final class ClaudeCheckTests: XCTestCase {
    private var fake: String { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("fake-claude").path }

    func testFakeClaudeAnswersVersionAndSignIn() {
        let status = ClaudeCheck.status(path: fake, environment: [:])
        XCTAssertEqual(status, ClaudeStatus(path: fake, version: "2.1.296", loggedIn: true, email: "bot@example.com"))
        XCTAssertNil(status.problem)
    }

    func testSignedOut() {
        let flag = NSTemporaryDirectory() + "serif-logged-out-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: flag, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: flag) }
        let status = ClaudeCheck.status(path: fake, environment: ["SERIF_FAKE_LOGGED_OUT": flag])
        XCTAssertEqual(status.loggedIn, false)
        XCTAssertEqual(status.problem, .notSignedIn)
    }

    func testNotFound() {
        XCTAssertEqual(ClaudeCheck.status(path: nil, environment: [:]).problem, .notInstalled)
        XCTAssertEqual(ClaudeCheck.status(path: "/nowhere/claude", environment: [:]).problem, .notInstalled)
    }

    func testOutputGivesUpAfterTheTimeout() {
        let start = Date()
        XCTAssertNil(ClaudeCheck.output("/bin/sleep", ["5"], [:], timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(ClaudeCheck.output("/bin/echo", ["hi"], [:]), "hi\n")
    }
}
