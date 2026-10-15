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
