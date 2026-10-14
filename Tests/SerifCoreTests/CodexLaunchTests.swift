import XCTest
@testable import SerifCore

final class CodexLaunchTests: XCTestCase {
    func testFreedomToCodex() {
        // Spec §5: approval and sandbox for each freedom.
        XCTAssertEqual(Freedom.allCases.map(\.codexApproval), ["untrusted", "on-request", "never"])
    }

    func testTokenAndItsHash() {
        let token = codexToken()
        XCTAssertEqual(token.count, 64)
        XCTAssertNotEqual(token, codexToken())
        XCTAssertEqual(codexTokenHash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")   // SHA-256 test vector
    }

    func testABotsServerIsIsolatedByItsCommandLine() {
        let args = codexServerArgs(listen: "ws://127.0.0.1:4000", tokenHash: "h",
                                   plugins: [(id: "browser@openai-bundled", enabled: false), (id: "pdf@openai-primary-runtime", enabled: true)],
                                   hiddenSkills: ["work-pets:pets", "work-pets:create-pet"], connectors: false)
        XCTAssertEqual(args, ["app-server", "--listen", "ws://127.0.0.1:4000", "--ws-auth", "capability-token", "--ws-token-sha256", "h",
                              "--disable", "hooks", "-c", "notify=[]",
                              "-c", "plugins.browser@openai-bundled.enabled=false",          // no quotes: quoted, Codex ignores it
                              "-c", "plugins.pdf@openai-primary-runtime.enabled=true",
                              "-c", #"skills.config=[{name="work-pets:pets",enabled=false},{name="work-pets:create-pet",enabled=false}]"#,
                              "--disable", "apps"])
    }

    func testConnectorsOnAndTheServiceServer() {
        let bot = codexServerArgs(listen: "ws://127.0.0.1:4000", tokenHash: "h", connectors: true)
        XCTAssertFalse(bot.contains("apps"))
        XCTAssertEqual(Array(bot.suffix(4)), ["--disable", "hooks", "-c", "notify=[]"])      // hooks off whatever else
    }

    func testThreadConfigNeverReplacesTheCommandLine() {
        // Review Focus 1: a thread `config` key replaces the same key given with -c, and Siigil's hooks fired (spec §3.6).
        for resume in [nil, "thr-1"] {
            for freedom in Freedom.allCases {
                let p = codexThreadParams(resume: resume, cwd: "/w", model: nil, instructions: "x", freedom: freedom, writableRoots: ["/w", "/s"])
                let keys = Set(p["config"]?.object?.keys.map { $0 } ?? [])
                XCTAssertEqual(keys, ["sandbox_workspace_write"])
                XCTAssertTrue(keys.isDisjoint(with: ["features", "plugins", "skills", "mcp_servers", "hooks", "notify"]))
            }
        }
    }

    func testThreadParams() {
        let start = codexThreadParams(resume: nil, cwd: "/w", model: "gpt-6-luna", instructions: "You are Cleo.", freedom: .edits,
                                      writableRoots: ["/w", "/s", "/l"])
        XCTAssertEqual(start, ["cwd": "/w", "developerInstructions": "You are Cleo.", "approvalPolicy": "on-request",
                               "sandbox": "workspace-write", "model": "gpt-6-luna",
                               "config": ["sandbox_workspace_write": ["writable_roots": ["/w", "/s", "/l"]]]])
        // Codex forgets the sandbox on resume (spec §3.5): everything again, plus the thread; Serif keeps the history itself.
        let resume = codexThreadParams(resume: "thr-1", cwd: "/w", model: nil, instructions: "x", freedom: .auto, writableRoots: [])
        XCTAssertEqual(resume["threadId"], "thr-1")
        XCTAssertEqual(resume["excludeTurns"], true)
        XCTAssertEqual(resume["approvalPolicy"], "never")
        XCTAssertNil(resume["model"])
    }

    func testEveryTurnPassesTheFreedomAgain() {
        // Codex keeps a turn's approval and sandbox for the turns after it: a turn typed in the terminal would leave its own.
        let roots: JSONValue = ["/w", "/s"]
        XCTAssertEqual(codexTurnPolicies(freedom: .ask, writableRoots: ["/w", "/s"]),
                       ["approvalPolicy": "untrusted", "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": roots]])
        XCTAssertEqual(codexTurnPolicies(freedom: .edits, writableRoots: ["/w", "/s"]),
                       ["approvalPolicy": "on-request", "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": roots]])
        XCTAssertEqual(codexTurnPolicies(freedom: .auto, writableRoots: ["/w", "/s"]),
                       ["approvalPolicy": "never", "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": roots]])
    }

    func testTerminalPlanAndEnvironment() {
        let plan = codexTerminalPlan(codexPath: "/bin/codex", threadId: "thr-1", port: 4000, token: "secret", cwd: "/w",
                                     baseEnvironment: ["PATH": "/bin", "CLAUDECODE": "1", "CODEX_THREAD_ID": "old", "CODEX_HOME": "/h"])
        XCTAssertEqual(plan.args, ["resume", "--remote", "ws://127.0.0.1:4000", "--remote-auth-token-env", "SERIF_CODEX_TOKEN",
                                   "--no-alt-screen", "thr-1"])
        XCTAssertEqual(plan.environment["SERIF_CODEX_TOKEN"], "secret")         // the secret never in the arguments
        XCTAssertNil(plan.environment["CLAUDECODE"])
        XCTAssertNil(plan.environment["CODEX_THREAD_ID"])
        XCTAssertEqual(plan.environment["CODEX_HOME"], "/h")                    // the user's Codex, never another home
        XCTAssertEqual(plan.cwd, "/w")
    }

    func testSettingsDriftIsAnythingBeyondTheBotsFreedom() {
        let policies = codexTurnPolicies(freedom: .ask, writableRoots: ["/w", "/s"])
        let same: JSONValue = .object(policies)
        XCTAssertFalse(codexSettingsDrift(same, policies: policies))
        XCTAssertFalse(codexSettingsDrift(["approvalPolicy": "untrusted",                  // fewer folders: still within it
                                           "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": ["/w"], "networkAccess": false]],
                                          policies: policies))
        for drift: JSONValue in [
            ["approvalPolicy": "on-request", "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": ["/w", "/s"]]],
            ["approvalPolicy": "untrusted", "sandboxPolicy": ["type": "dangerFullAccess"]],
            ["approvalPolicy": "untrusted", "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": ["/w", "/Users/me"]]],
            ["approvalPolicy": "untrusted", "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": ["/w"], "networkAccess": true]],
            ["approvalPolicy": "untrusted"],
        ] {
            XCTAssertTrue(codexSettingsDrift(drift, policies: policies), "\(drift)")
        }
    }

    func testCodexMemoryIsAgentsMD() {
        let project = Project(name: "P")
        let codex = Bot(projectId: project.id, name: "Cleo", face: BotFace(shape: .ball, body: 0, eyes: 0xFFFFFF), agent: .codex)
        let paths = SerifPaths(root: URL(fileURLWithPath: "/tmp/s"))
        XCTAssertTrue(systemPrompt(bot: codex, project: project, paths: paths, linkedInstructions: nil).contains("Your memory is AGENTS.md"))
        var claude = codex
        claude.agent = .claude
        XCTAssertTrue(systemPrompt(bot: claude, project: project, paths: paths, linkedInstructions: nil).contains("Your memory is CLAUDE.md"))
    }
}
