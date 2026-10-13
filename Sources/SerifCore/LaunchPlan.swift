import Foundation

public struct LaunchPlan: Equatable, Sendable {
    public let executable: String
    public let args: [String]
    public let environment: [String: String]
    public let cwd: String

    public init(executable: String, args: [String], environment: [String: String], cwd: String) {
        self.executable = executable; self.args = args; self.environment = environment; self.cwd = cwd
    }
}

/// The engine's environment as Claude Code gets it, for the bots and for the engine's own check of Claude Code: no
/// `CLAUDE*` variables and no `ANTHROPIC_API_KEY` (bots use the subscription).
public func botEnvironment(_ base: [String: String]) -> [String: String] {
    base.filter { !$0.key.hasPrefix("CLAUDE") && $0.key != "ANTHROPIC_API_KEY" }
}

public func claudeLaunchPlan(bot: Bot, project: Project, paths: SerifPaths, claudePath: String, resume: Bool,
                             baseEnvironment: [String: String], token: String, linkedFolderExists: Bool,
                             pluginFolders: [String] = []) -> LaunchPlan {
    let botPaths = paths.bot(bot.id)
    var args = ["--setting-sources", "project,local",
                "--settings", botPaths.settings.path,
                "--permission-mode", bot.freedom.claudePermissionMode,
                "--append-system-prompt-file", botPaths.systemPrompt.path,
                "--add-dir", paths.shared(project.id).path]
    if linkedFolderExists, let linked = project.linkedFolder { args += ["--add-dir", linked] }
    for folder in pluginFolders { args += ["--plugin-dir", folder] }
    if let model = bot.model { args += ["--model", model] }
    args += resume ? ["--resume", bot.sessionId.uuidString] : ["--session-id", bot.sessionId.uuidString]

    var env = botEnvironment(baseEnvironment)
    // Never offer "resume from summary?" on --resume: that prompt blocks the bot (same fix as Gravity).
    env["CLAUDE_CODE_RESUME_THRESHOLD_MINUTES"] = "525600"
    env["CLAUDE_CODE_RESUME_TOKEN_THRESHOLD"] = "1000000000"
    // claude.ai's connectors reach a bot despite --setting-sources (spec §3.3): off unless the bot turns them on. Not
    // --strict-mcp-config: it would also drop the servers the bot's plugins bring (verified 13/10 with figma).
    if !bot.connectors { env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false" }
    env["SERIF_BOT_ID"] = bot.id.uuidString
    env["SERIF_HOOK_SOCKET"] = paths.hookSocket.path
    env["SERIF_TOKEN"] = token
    env["TERM"] = "xterm-256color"
    return LaunchPlan(executable: claudePath, args: args, environment: env, cwd: botPaths.workspace.path)
}

/// The contents of the bot's `settings.json`: every hook event runs `hookCommand`.
public func claudeHookSettings(hookCommand: String) -> Data {
    let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "MessageDisplay", "PreToolUse", "PostToolUse",
                  "PostToolUseFailure", "PostToolBatch", "PermissionRequest", "Notification", "Stop", "StopFailure",
                  "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"]
    // The app path may contain spaces or quotes: single-quote it for the shell.
    let quoted = "'" + hookCommand.replacingOccurrences(of: "'", with: "'\\''") + "'"
    var hooks: [String: Any] = [:]
    for e in events {
        var entry: [String: Any] = ["type": "command", "command": quoted]
        if e == "PermissionRequest" { entry["timeout"] = 3600 }
        hooks[e] = [["hooks": [entry]]]
    }
    let root: [String: Any] = ["hooks": hooks, "crossSessionInbound": "refuse"]
    return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
}

public func systemPrompt(bot: Bot, project: Project, paths: SerifPaths, linkedInstructions: String?) -> String {
    var s = "You are \(bot.name), a bot in the project \"\(project.name)\".\n"
    if !bot.instructions.isEmpty { s += "\nYour role:\n\(bot.instructions)\n" }
    s += "\nThe folder shared by all bots of this project: \(paths.shared(project.id).path)\n"
    if let linked = project.linkedFolder { s += "The project's linked folder: \(linked)\n" }
    s += "\nYour memory is CLAUDE.md in your working folder: keep it up to date.\n"
    if let linkedInstructions { s += "\nInstructions from the linked folder:\n" + linkedInstructions + "\n" }
    return s
}

/// The first message Serif sends a new bot (spec §5), queued until its session is ready. With instructions it introduces
/// itself, without them it asks what it is for; the first bot a project ever had also gives a short tour. Answered in
/// `language`, an English name ("Italian").
public func introductionPrompt(instructions: String, firstInProject: Bool, language: String) -> String {
    var s = instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "You have just been created, with no instructions. Greet the user in one brief, friendly sentence, then ask "
            + "what job they want you to take on. Do not invent a purpose."
        : "You have just been created. Briefly introduce yourself — who you are, what you understand your job to be, and "
            + "how you can help — in no more than three sentences. Finish with what you plan to do first, or what you need "
            + "before you can start."
    if firstInProject {
        s += "\n\nBecause you are the first bot in this project, also give the user a short tour of what they can ask for: "
            + "four or five one-line bullets, plainly worded, no tool names, picked from these:\n"
            + "- they can change your name, face and instructions in your settings;\n"
            + "- you work in your own folder and put files to share in the project's folder, which every bot of the project can read;\n"
            + "- you keep notes across sessions, so what they tell you now is not lost;\n"
            + "- your terminal is one click away;\n"
            + "- they can give you skills and plugins in your settings."
    }
    return s + "\n\nReply in \(language). Do not start any other work yet."
}

/// The English name of the Mac's first language ("it-IT" → "Italian"), for the introduction; English when unknown.
public func languageName(preferredLanguages: [String]) -> String {
    guard let first = preferredLanguages.first, let code = Locale(identifier: first).language.languageCode?.identifier,
          let name = Locale(identifier: "en").localizedString(forLanguageCode: code) else { return "English" }
    return name
}
