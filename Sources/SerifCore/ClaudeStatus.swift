import Foundation

/// Claude Code as the engine found it (spec §4): where it is, its version, whether it is signed in. `loggedIn` is nil when
/// `claude auth status` did not answer: unknown, and bots launch anyway (spec §9).
public struct ClaudeStatus: Codable, Equatable, Sendable {
    public var path: String?
    public var version: String?
    public var loggedIn: Bool?
    public var email: String?

    public init(path: String?, version: String?, loggedIn: Bool?, email: String?) {
        self.path = path; self.version = version; self.loggedIn = loggedIn; self.email = email
    }

    public var installed: Bool { path != nil }

    /// What keeps bots from starting, if anything.
    public var problem: ClaudeProblem? {
        if path == nil { return .notInstalled }
        return loggedIn == false ? .notSignedIn : nil
    }
}

/// Why a bot stopped before Claude Code started. The raw value is the crash reason itself (`BotState.crashed`), so the app
/// recognises it and shows the Claude Code help in the bot's chat (spec §4).
public enum ClaudeProblem: String, Sendable {
    case notInstalled = "Claude Code not installed"
    case notSignedIn = "Claude Code is not signed in"
}

/// The version `claude --version` prints first: "2.1.296 (Claude Code)" → "2.1.296".
public func claudeVersion(_ output: String) -> String? {
    output.split(whereSeparator: \.isWhitespace).first.map(String.init)
}

/// Sign-in state from `claude auth status`, a JSON object with `loggedIn`, `authMethod`, `email` (spec §3.5). Output that
/// is not that JSON leaves both unknown.
public func claudeAuth(_ output: String) -> (loggedIn: Bool?, email: String?) {
    guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
          let json = try? JSONValue.parse(Data(output[start...end].utf8)) else { return (nil, nil) }
    return (json["loggedIn"]?.bool, json["email"]?.string)
}
