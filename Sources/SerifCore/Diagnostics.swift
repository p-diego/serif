import Foundation

// Diagnostics (spec §8 of 0.7): what the window shows and what "Copy" puts on the pasteboard. Never a secret (no token,
// no email) and never a chat's text.

/// An agent as the engine last checked it.
public struct AgentDiagnostics: Codable, Equatable, Sendable {
    public var agent: Agent
    public var path: String?
    public var version: String?
    public var signedIn: Bool?

    public init(agent: Agent, path: String?, version: String?, signedIn: Bool?) {
        self.agent = agent; self.path = path; self.version = version; self.signedIn = signedIn
    }
}

/// A live bot: its state, its last crash, what waits for it.
public struct BotDiagnostics: Codable, Equatable, Sendable {
    public struct Crash: Codable, Equatable, Sendable {
        public var at: Date
        public var reason: String
        public init(at: Date, reason: String) { self.at = at; self.reason = reason }
    }
    public struct RoutineNext: Codable, Equatable, Sendable {
        public var name: String
        public var next: Date?
        public init(name: String, next: Date?) { self.name = name; self.next = next }
    }

    public var name: String
    public var project: String
    public var agent: Agent
    public var state: BotState
    public var lastCrash: Crash?
    public var mailWaiting: Int
    public var routines: [RoutineNext]
    public var openCards: Int

    public init(name: String, project: String, agent: Agent, state: BotState, lastCrash: Crash?, mailWaiting: Int,
                routines: [RoutineNext], openCards: Int) {
        self.name = name; self.project = project; self.agent = agent; self.state = state; self.lastCrash = lastCrash
        self.mailWaiting = mailWaiting; self.routines = routines; self.openCards = openCards
    }
}

/// The whole page. `appVersion` is the app's: the engine leaves it empty, the app fills it before showing.
public struct Diagnostics: Codable, Equatable, Sendable {
    public var appVersion: String
    public var engineVersion: String
    public var dataFolder: String
    public var agents: [AgentDiagnostics]
    public var bots: [BotDiagnostics]
    /// The last 100 lines of serifd.log.
    public var logTail: [String]

    public init(appVersion: String, engineVersion: String, dataFolder: String, agents: [AgentDiagnostics],
                bots: [BotDiagnostics], logTail: [String]) {
        self.appVersion = appVersion; self.engineVersion = engineVersion; self.dataFolder = dataFolder
        self.agents = agents; self.bots = bots; self.logTail = logTail
    }
}

public func agentName(_ agent: Agent) -> String { agent == .claude ? "Claude Code" : "Codex" }

/// A bot's state in a word, for the bots and for the page (crash reasons kept).
public func stateWord(_ state: BotState) -> String {
    switch state {
    case .ready: "ready"
    case .starting: "starting"
    case .working: "working"
    case .waiting: "waiting for the user"
    case .rateLimited: "at its usage limit"
    case .crashed(let reason, let retry): retry == nil ? "stopped: \(reason)" : "crashed: \(reason), starting again"
    case .stopped: "stopped"
    }
}

/// The page as plain text for "Copy" (spec §8): English, like the log, to paste into a conversation.
public func diagnosticsText(_ d: Diagnostics, timeZone: TimeZone = .current) -> String {
    var lines = ["Serif \(d.appVersion) · engine \(d.engineVersion)", "Data folder: \(d.dataFolder)", "", "Agents"]
    for a in d.agents {
        guard let path = a.path else { lines.append("- \(agentName(a.agent)): not installed"); continue }
        let signed = a.signedIn.map { $0 ? "signed in" : "not signed in" } ?? "sign-in unknown"
        lines.append("- \(agentName(a.agent)): \(path), \(a.version ?? "version unknown"), \(signed)")
    }
    lines += ["", "Bots"]
    if d.bots.isEmpty { lines.append("- none") }
    for b in d.bots {
        let routines = b.routines.isEmpty ? "none"
            : b.routines.map { "\($0.name) (next \($0.next.map { mailDate($0, timeZone: timeZone) } ?? "never"))" }
                .joined(separator: ", ")
        lines.append("- \(b.name) (\(b.project), \(agentName(b.agent))): \(stateWord(b.state)); "
                     + "mail waiting: \(b.mailWaiting); open cards: \(b.openCards); routines: \(routines)")
        if let c = b.lastCrash { lines.append("  last crash: \(mailDate(c.at, timeZone: timeZone)) — \(c.reason)") }
    }
    lines += ["", "Log (last \(d.logTail.count) lines)"] + d.logTail
    return lines.joined(separator: "\n")
}
