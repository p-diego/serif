import XCTest
@testable import SerifCore

final class ClaudeStatusTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(claudeVersion("2.1.296 (Claude Code)\n"), "2.1.296")
        XCTAssertNil(claudeVersion("  \n"))
    }

    func testAuthOutput() {
        let signedIn = """
        {
          "loggedIn": true,
          "authMethod": "claude.ai",
          "email": "diego@example.com"
        }
        """
        XCTAssertEqual(claudeAuth(signedIn).loggedIn, true)
        XCTAssertEqual(claudeAuth(signedIn).email, "diego@example.com")
        XCTAssertEqual(claudeAuth(#"{"loggedIn": false, "authMethod": "none"}"#).loggedIn, false)
        XCTAssertNil(claudeAuth(#"{"loggedIn": false}"#).email)
    }

    func testAuthOutputThatIsNotJSONIsUnknown() {
        for text in ["", "Error: something went wrong", "} {", #"{"loggedIn": "yes"}"#] {
            XCTAssertNil(claudeAuth(text).loggedIn, text)
        }
    }

    func testProblem() {
        XCTAssertEqual(ClaudeStatus(path: nil, version: nil, loggedIn: nil, email: nil).problem, .notInstalled)
        XCTAssertEqual(ClaudeStatus(path: "/c", version: "2", loggedIn: false, email: nil).problem, .notSignedIn)
        XCTAssertNil(ClaudeStatus(path: "/c", version: "2", loggedIn: nil, email: nil).problem)    // unknown: launch anyway (spec §9)
        XCTAssertNil(ClaudeStatus(path: "/c", version: nil, loggedIn: true, email: nil).problem)
        XCTAssertTrue(ClaudeStatus(path: "/c", version: nil, loggedIn: nil, email: nil).installed)
    }
}
