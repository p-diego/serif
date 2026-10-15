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
        XCTAssertTrue(plan.args.containsSequence(["--mcp-config", paths.bot(bot.id).mcpConfig.path]))
        XCTAssertFalse(plan.args.contains("--strict-mcp-config"))
    }

    func testToolsConfigCarriesTheSecretInItsEnvironment() throws {
        let bot = UUID()
        let v = try JSONValue.parse(claudeToolsConfig(command: "/My Apps/Serif.app/Contents/MacOS/serif-tools", bot: bot, token: "t",
                                                      hookSocket: "/tmp/s/hook.sock"))
        XCTAssertEqual(v, ["mcpServers": ["serif": ["command": "/My Apps/Serif.app/Contents/MacOS/serif-tools",
                                                     "env": ["SERIF_BOT_ID": .string(bot.uuidString), "SERIF_TOKEN": "t",
                                                             "SERIF_HOOK_SOCKET": "/tmp/s/hook.sock"]]]])
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
        XCTAssertEqual(v["permissions"], ["allow": ["mcp__serif"]])       // Serif's tools never ask (spec §4)
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

    func testSystemPromptNamesColleaguesTheLeadAndTheTools() {
        var proj = Project(name: "P")
        let face = BotFace(shape: .allCases[0], body: 1, eyes: 2)
        let ada = Bot(projectId: proj.id, name: "Ada", face: face)
        let milo = Bot(projectId: proj.id, name: "Milo", face: face)
        let old = Bot(projectId: proj.id, name: "Old", face: face, archivedAt: Date())
        let paths = SerifPaths(root: URL(fileURLWithPath: "/tmp/s"))
        proj.leadBotId = milo.id
        let s = systemPrompt(bot: ada, project: proj, paths: paths, linkedInstructions: nil, bots: [ada, milo, old])
        XCTAssertTrue(s.contains("Your colleagues in this project: Milo (the project's lead)."))
        XCTAssertFalse(s.contains("Old"))
        XCTAssertTrue(s.contains(serifToolsGuide))
        XCTAssertTrue(serifToolsGuide.contains("complete_task") && serifToolsGuide.contains("shared folder"))
        XCTAssertTrue(systemPrompt(bot: milo, project: proj, paths: paths, linkedInstructions: nil, bots: [ada, milo])
            .contains("You are the project's lead"))
        XCTAssertTrue(systemPrompt(bot: ada, project: proj, paths: paths, linkedInstructions: nil, bots: [ada])
            .contains("No other bot is in this project yet."))
    }

    func testPluginsAndConnectors() {
        let proj = Project(name: "P")
        var bot = Bot(projectId: proj.id, name: "B", face: BotFace(shape: .allCases[0], body: 1, eyes: 2))
        let paths = SerifPaths(root: URL(fileURLWithPath: "/tmp/s"))
        func args(_ bot: Bot, _ plugins: [String]) -> [String] {
            claudeLaunchPlan(bot: bot, project: proj, paths: paths, claudePath: "/c", resume: false, baseEnvironment: [:],
                             token: "t", linkedFolderExists: false, pluginFolders: plugins).args
        }
        func env(_ bot: Bot) -> [String: String] {
            claudeLaunchPlan(bot: bot, project: proj, paths: paths, claudePath: "/c", resume: false, baseEnvironment: [:],
                             token: "t", linkedFolderExists: false).environment
        }
        let off = args(bot, ["/p/a", "/p/b"])
        XCTAssertTrue(off.containsSequence(["--plugin-dir", "/p/a", "--plugin-dir", "/p/b"]))
        XCTAssertFalse(off.contains("--strict-mcp-config"))         // it would also drop the plugins' own MCP servers
        XCTAssertEqual(env(bot)["ENABLE_CLAUDEAI_MCP_SERVERS"], "false")   // claude.ai connectors off by default (spec §6.2)
        bot.connectors = true
        XCTAssertNil(env(bot)["ENABLE_CLAUDEAI_MCP_SERVERS"])
        XCTAssertFalse(args(bot, []).contains("--plugin-dir"))
    }

    func testIntroductionPrompt() {
        let withRole = introductionPrompt(instructions: "Review code.", firstInProject: false, language: "Italian")
        XCTAssertTrue(withRole.contains("three sentences"))
        XCTAssertFalse(withRole.contains("Do not invent a purpose"))
        XCTAssertFalse(withRole.contains("first bot in this project"))
        let blank = introductionPrompt(instructions: " \n", firstInProject: false, language: "Italian")
        XCTAssertTrue(blank.contains("Do not invent a purpose"))
        XCTAssertFalse(blank.contains("three sentences"))
        let first = introductionPrompt(instructions: "", firstInProject: true, language: "English")
        XCTAssertTrue(first.contains("first bot in this project"))
        XCTAssertTrue(first.contains("skills and plugins"))
        XCTAssertTrue(first.contains("a short tour of what they can do with you"))
        XCTAssertTrue(first.contains("no tool or file names"))
        XCTAssertTrue(first.contains("- you keep notes you don't lose between sessions;"))
        for prompt in [withRole, blank, first] { XCTAssertTrue(prompt.hasSuffix("Do not start any other work yet.")) }
        XCTAssertTrue(withRole.contains("Reply in Italian."))
        XCTAssertTrue(first.contains("Reply in English."))
    }

    func testLanguageName() {
        XCTAssertEqual(languageName(preferredLanguages: ["it-IT", "en-US"]), "Italian")
        XCTAssertEqual(languageName(preferredLanguages: ["en-GB"]), "English")
        XCTAssertEqual(languageName(preferredLanguages: ["pt-BR"]), "Portuguese")
        XCTAssertEqual(languageName(preferredLanguages: []), "English")
    }
}
