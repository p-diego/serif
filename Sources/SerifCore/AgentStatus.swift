import Foundation

/// An agent's command-line tool as the engine found it (spec §4 of 0.3, §8): where it is, its version, whether it is
/// signed in. `loggedIn` is nil when the sign-in check did not answer: unknown, and bots launch anyway.
public struct AgentStatus: Codable, Equatable, Sendable {
    public var agent: Agent
    public var path: String?
    public var version: String?
    public var loggedIn: Bool?
    public var email: String?

    public init(agent: Agent, path: String?, version: String?, loggedIn: Bool?, email: String?) {
        self.agent = agent; self.path = path; self.version = version; self.loggedIn = loggedIn; self.email = email
    }

    public var installed: Bool { path != nil }

    /// What keeps this agent's bots from starting, if anything.
    public var problem: AgentProblem? {
        if path == nil { return agent == .claude ? .claudeNotInstalled : .codexNotInstalled }
        guard loggedIn == false else { return nil }
        return agent == .claude ? .claudeNotSignedIn : .codexNotSignedIn
    }
}

/// Why a bot stopped before its agent started. The raw value is the crash reason itself (`BotState.crashed`), so the app
/// recognises it and shows that agent's help in the bot's chat.
public enum AgentProblem: String, Sendable {
    case claudeNotInstalled = "Claude Code not installed"
    case claudeNotSignedIn = "Claude Code is not signed in"
    case codexNotInstalled = "Codex not installed"
    case codexNotSignedIn = "Codex is not signed in"
}

/// The version `claude --version` prints first: "2.1.296 (Claude Code)" → "2.1.296".
public func claudeVersion(_ output: String) -> String? {
    output.split(whereSeparator: \.isWhitespace).first.map(String.init)
}

/// Sign-in state from `claude auth status`, a JSON object with `loggedIn`, `authMethod`, `email` (spec §3.5 of 0.3). Output
/// that is not that JSON leaves both unknown.
public func claudeAuth(_ output: String) -> (loggedIn: Bool?, email: String?) {
    guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
          let json = try? JSONValue.parse(Data(output[start...end].utf8)) else { return (nil, nil) }
    return (json["loggedIn"]?.bool, json["email"]?.string)
}

/// The version `codex --version` prints last: "codex-cli 0.160.0" → "0.160.0".
public func codexVersion(_ output: String) -> String? {
    output.split(whereSeparator: \.isWhitespace).last.map(String.init)
}

/// Sign-in state from `codex login status`: "Logged in using ChatGPT" (or an API key) is signed in, "Not logged in" is not;
/// anything else is unknown.
public func codexLoggedIn(_ output: String) -> Bool? {
    if output.contains("Not logged in") { return false }
    return output.contains("Logged in") ? true : nil
}
