import XCTest
@testable import SerifCore

final class AgentStatusTests: XCTestCase {
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
        XCTAssertEqual(AgentStatus(agent: .claude, path: nil, version: nil, loggedIn: nil, email: nil).problem, .claudeNotInstalled)
        XCTAssertEqual(AgentStatus(agent: .claude, path: "/c", version: "2", loggedIn: false, email: nil).problem, .claudeNotSignedIn)
        XCTAssertNil(AgentStatus(agent: .claude, path: "/c", version: "2", loggedIn: nil, email: nil).problem)    // unknown: launch anyway (spec §9)
        XCTAssertNil(AgentStatus(agent: .claude, path: "/c", version: nil, loggedIn: true, email: nil).problem)
        XCTAssertTrue(AgentStatus(agent: .claude, path: "/c", version: nil, loggedIn: nil, email: nil).installed)
    }

    func testCodexOutput() {
        XCTAssertEqual(codexVersion("codex-cli 0.160.0\n"), "0.160.0")
        XCTAssertNil(codexVersion("\n"))
        XCTAssertEqual(codexLoggedIn("Logged in using ChatGPT\n"), true)        // 0.160.0, on standard error
        XCTAssertEqual(codexLoggedIn("Logged in using an API key - sk-***\n"), true)
        XCTAssertEqual(codexLoggedIn("Not logged in\n"), false)
        XCTAssertNil(codexLoggedIn(""))
        XCTAssertNil(codexLoggedIn("Error: something went wrong"))
    }

    func testEachAgentHasItsOwnProblems() {
        XCTAssertEqual(AgentStatus(agent: .codex, path: nil, version: nil, loggedIn: nil, email: nil).problem, .codexNotInstalled)
        XCTAssertEqual(AgentStatus(agent: .codex, path: "/c", version: nil, loggedIn: false, email: nil).problem, .codexNotSignedIn)
        XCTAssertNil(AgentStatus(agent: .codex, path: "/c", version: nil, loggedIn: nil, email: nil).problem)
        // The reason a stopped bot shows is the problem itself, and the app reads it back (spec §4 of 0.3).
        XCTAssertEqual(AgentProblem(rawValue: "Claude Code not installed"), .claudeNotInstalled)
        XCTAssertEqual(AgentProblem(rawValue: AgentProblem.codexNotSignedIn.rawValue), .codexNotSignedIn)
    }
}
