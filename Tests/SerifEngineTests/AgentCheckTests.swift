import XCTest
import SerifCore
@testable import SerifEngine

final class AgentCheckTests: XCTestCase {
    private var fake: String { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("fake-claude").path }

    func testFakeClaudeAnswersVersionAndSignIn() {
        let status = AgentCheck.status(.claude, path: fake, environment: [:])
        XCTAssertEqual(status, AgentStatus(agent: .claude, path: fake, version: "2.1.296", loggedIn: true, email: "bot@example.com"))
        XCTAssertNil(status.problem)
    }

    func testSignedOut() {
        let flag = NSTemporaryDirectory() + "serif-logged-out-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: flag, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: flag) }
        let status = AgentCheck.status(.claude, path: fake, environment: ["SERIF_FAKE_LOGGED_OUT": flag])
        XCTAssertEqual(status.loggedIn, false)
        XCTAssertEqual(status.problem, .claudeNotSignedIn)
    }

    func testNotFound() {
        XCTAssertEqual(AgentCheck.status(.claude, path: nil, environment: [:]).problem, .claudeNotInstalled)
        XCTAssertEqual(AgentCheck.status(.claude, path: "/nowhere/claude", environment: [:]).problem, .claudeNotInstalled)
    }

    func testOutputGivesUpAfterTheTimeout() {
        let start = Date()
        XCTAssertNil(AgentCheck.output("/bin/sleep", ["5"], [:], timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(AgentCheck.output("/bin/echo", ["hi"], [:]), "hi\n")
    }

    private var fakeCodex: String { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("fake-codex").path }

    func testCodexAnswersItsSignInOnStandardError() {
        XCTAssertEqual(AgentCheck.status(.codex, path: fakeCodex, environment: [:]),
                       AgentStatus(agent: .codex, path: fakeCodex, version: "0.160.0", loggedIn: true, email: nil))
        let flag = NSTemporaryDirectory() + "serif-codex-out-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: flag, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: flag) }
        XCTAssertEqual(AgentCheck.status(.codex, path: fakeCodex, environment: ["SERIF_FAKE_CODEX_LOGGED_OUT": flag]).problem, .codexNotSignedIn)
        XCTAssertEqual(AgentCheck.output("/bin/sh", ["-c", "echo out; echo err >&2"], [:], readErrors: true), "out\nerr\n")
        XCTAssertEqual(AgentCheck.output("/bin/sh", ["-c", "echo out; echo err >&2"], [:]), "out\n")
    }
}

final class AgentCheckHangTests: XCTestCase {
    private func assertGivesUp(_ script: String) {
        let start = Date()
        XCTAssertNil(AgentCheck.output("/bin/sh", ["-c", script], [:], timeout: 0.3), script)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, script)
    }

    func testIgnoringSIGTERM() { assertGivesUp("trap '' TERM; sleep 5") }
    func testGrandchildHoldingTheOutput() { assertGivesUp("sleep 5 & echo hi") }
}
