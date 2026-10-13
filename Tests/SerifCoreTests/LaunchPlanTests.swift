import XCTest
@testable import SerifCore

final class LaunchPlanTests: XCTestCase {
    private func make(resume: Bool, linked: Bool) -> (LaunchPlan, Bot, SerifPaths) {
        let proj = Project(name: "P", linkedFolder: "/Users/x/repo")
        let bot = Bot(projectId: proj.id, name: "B", face: BotFace(shape: .allCases[0], body: 1, eyes: 2), model: "haiku", freedom: .edits)
        let paths = SerifPaths(root: URL(fileURLWithPath: "/tmp/s"))
        let plan = claudeLaunchPlan(bot: bot, project: proj, paths: paths, claudePath: "/opt/claude", resume: resume,
            baseEnvironment: ["PATH": "/bin", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "x", "ANTHROPIC_API_KEY": "k", "HOME": "/Users/x"],
            token: "t", linkedFolderExists: linked)
        return (plan, bot, paths)
    }

    func testLaunchPlanStripsClaudeAndApiKey() {
        let (plan, bot, paths) = make(resume: false, linked: true)
        XCTAssertNil(plan.environment["CLAUDECODE"]); XCTAssertNil(plan.environment["CLAUDE_CODE_ENTRYPOINT"])
        XCTAssertNil(plan.environment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(plan.environment["HOME"], "/Users/x")
        // No blocking "resume from summary?" prompt on --resume.
        XCTAssertEqual(plan.environment["CLAUDE_CODE_RESUME_THRESHOLD_MINUTES"], "525600")
        XCTAssertEqual(plan.environment["CLAUDE_CODE_RESUME_TOKEN_THRESHOLD"], "1000000000")
        XCTAssertEqual(plan.environment["SERIF_BOT_ID"], bot.id.uuidString); XCTAssertEqual(plan.environment["SERIF_TOKEN"], "t")
        XCTAssertEqual(plan.environment["SERIF_HOOK_SOCKET"], "/tmp/s/hook.sock"); XCTAssertEqual(plan.environment["TERM"], "xterm-256color")
        XCTAssertEqual(plan.executable, "/opt/claude")
        XCTAssertEqual(plan.cwd, paths.bot(bot.id).workspace.path)
        XCTAssertEqual(Array(plan.args.prefix(2)), ["--setting-sources", "project,local"])
        XCTAssertTrue(plan.args.containsSequence(["--permission-mode", "acceptEdits"]))
        XCTAssertTrue(plan.args.containsSequence(["--session-id", bot.sessionId.uuidString]))
        XCTAssertTrue(plan.args.containsSequence(["--add-dir", "/Users/x/repo"]))
        XCTAssertTrue(plan.args.containsSequence(["--model", "haiku"]))
    }

    func testResumeUsesResume() {
        let (plan, bot, _) = make(resume: true, linked: false)
        XCTAssertTrue(plan.args.containsSequence(["--resume", bot.sessionId.uuidString]))
        XCTAssertFalse(plan.args.contains("--session-id"))
        XCTAssertFalse(plan.args.contains("/Users/x/repo"))
    }

    func testHookSettingsCoverAllEvents() throws {
        let v = try JSONValue.parse(claudeHookSettings(hookCommand: "/Applications/Serif.app/Contents/MacOS/serif-hook"))
        for e in ["UserPromptSubmit", "MessageDisplay", "PreToolUse", "PostToolBatch", "PermissionRequest", "Stop"] {
            XCTAssertNotNil(v["hooks"]?[e], e)
        }
        XCTAssertEqual(v["hooks"]?["PermissionRequest"]?.array?[0]["hooks"]?.array?[0]["timeout"]?.int, 3600)
        XCTAssertEqual(v["crossSessionInbound"]?.string, "refuse")
    }

    func testHookCommandIsShellQuoted() throws {
        let v = try JSONValue.parse(claudeHookSettings(hookCommand: "/My Apps/it's/serif-hook"))
        XCTAssertEqual(v["hooks"]?["Stop"]?.array?[0]["hooks"]?.array?[0]["command"]?.string, #"'/My Apps/it'\''s/serif-hook'"#)
    }

    func testSystemPrompt() {
        let proj = Project(name: "P", linkedFolder: "/Users/x/repo")
        let bot = Bot(projectId: proj.id, name: "Ada", face: BotFace(shape: .allCases[0], body: 1, eyes: 2), instructions: "Review code.")
        let paths = SerifPaths(root: URL(fileURLWithPath: "/tmp/s"))
        let s = systemPrompt(bot: bot, project: proj, paths: paths, linkedInstructions: "Be kind.")
        for part in ["Ada", "P", "Review code.", paths.shared(proj.id).path, "/Users/x/repo", "CLAUDE.md", "Instructions from the linked folder:\nBe kind."] {
            XCTAssertTrue(s.contains(part), part)
        }
        XCTAssertFalse(systemPrompt(bot: bot, project: proj, paths: paths, linkedInstructions: nil).contains("Instructions from"))
    }
}
