import Foundation

// Protocol between the app and the engine (serifd): one JSON object per line.

/// A bot as the app lists it, with its state and a preview of its latest activity.
public struct BotSummary: Codable, Equatable, Sendable {
    public var bot: Bot
    public var state: BotState
    public var unread: Bool
    public var lastEvent: ChatEventRecord?      // for row preview/time
    public var preview: String?                 // last assistant text or request summary

    public init(bot: Bot, state: BotState, unread: Bool, lastEvent: ChatEventRecord?, preview: String?) {
        self.bot = bot
        self.state = state
        self.unread = unread
        self.lastEvent = lastEvent
        self.preview = preview
    }
}

/// Everything the app needs to draw its window after connecting.
public struct Snapshot: Codable, Equatable, Sendable {
    public var projects: [Project]
    public var bots: [BotSummary]
    public var requests: [PendingRequest]
    /// Every project's routines (spec §4 of 0.6).
    public var routines: [Routine]
    public var engineVersion: String

    public init(projects: [Project], bots: [BotSummary], requests: [PendingRequest], routines: [Routine] = [],
                engineVersion: String) {
        self.projects = projects
        self.bots = bots
        self.requests = requests
        self.routines = routines
        self.engineVersion = engineVersion
    }
}

/// The fields the app chooses when creating a bot.
public struct NewBot: Codable, Equatable, Sendable {
    public var projectId: UUID
    public var name: String
    public var face: BotFace
    public var agent: Agent
    public var model: String?
    public var instructions: String
    public var freedom: Freedom
    public var skills: [String]
    public var plugins: [String]
    public var connectors: Bool

    public init(projectId: UUID, name: String, face: BotFace, agent: Agent, model: String?,
                instructions: String, freedom: Freedom, skills: [String] = [], plugins: [String] = [], connectors: Bool = false) {
        self.projectId = projectId
        self.name = name
        self.face = face
        self.agent = agent
        self.model = model
        self.instructions = instructions
        self.freedom = freedom
        self.skills = skills
        self.plugins = plugins
        self.connectors = connectors
    }
}

/// A request from the app to the engine. Each one is wrapped in a `RequestEnvelope` with an id.
public enum AppRequest: Codable, Equatable, Sendable {
    case hello(protocolVersion: Int)
    case snapshot
    case createProject(name: String, linkedFolder: String?, readLinkedInstructions: Bool)
    case updateProject(Project)
    case archiveProject(id: UUID)
    case createBot(NewBot)
    case updateBot(Bot)
    case archiveBot(id: UUID)
    case restartBot(id: UUID)
    case history(botId: UUID, beforeSeq: Int?, limit: Int)
    case send(botId: UUID, text: String, attachments: [String]? = nil)   // files already attached, by path (spec §4 of 0.7)
    case interrupt(botId: UUID)
    case answer(requestId: UUID, answer: RequestAnswer)
    case markRead(botId: UUID, seq: Int)
    case attachTerminal(botId: UUID)
    case detachTerminal(botId: UUID)
    case terminalInput(botId: UUID, data: Data)
    case resizeTerminal(botId: UUID, cols: Int, rows: Int)
    case agentStatus(Agent)     // the agent installed and signed in? Checked again on every request (spec §4 of 0.3)
    case codexCatalog           // Codex's plugins and models for the sheets (spec §6), kept a few minutes
    case cancelTask(projectId: UUID, number: Int)   // the user's Cancel on a task's card (spec §9 of 0.5)
    case saveRoutine(Routine)                       // the sheet's Save, new or changed (spec §4 of 0.6)
    case deleteRoutine(id: UUID)
    case runRoutine(id: UUID)                       // "Run now": a run as soon as the bot is free
    case decisions(projectId: UUID)                 // the project's decisions, for its settings (spec §6 of 0.6)
    case attach(botId: UUID, files: [AttachedFile]) // copies the files into the shared folder; answers their paths (spec §4 of 0.7)
    case changes(botId: UUID)                       // the bot's history, newest last (spec §5 of 0.7)
    case changeAgent(botId: UUID, agent: Agent)     // Claude Code ↔ Codex, with confirmation in the app (spec §7 of 0.7)
    case diagnostics                                // the Diagnostics window (spec §8 of 0.7)
    case shutdown
}

/// A file the app sends with a message (spec §4 of 0.7): its name as the user had it, and its bytes.
public struct AttachedFile: Codable, Equatable, Sendable {
    public var name: String
    public var data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

/// Pairs a request with the id the engine echoes back in its response.
public struct RequestEnvelope: Codable, Equatable, Sendable {
    public let id: Int
    public let request: AppRequest

    public init(id: Int, request: AppRequest) {
        self.id = id
        self.request = request
    }
}

/// The engine's answer to one request.
public enum ResponseBody: Codable, Equatable, Sendable {
    case ok
    case welcome(protocolVersion: Int, engineVersion: String)
    case snapshot(Snapshot)
    case project(Project)
    case bot(Bot)
    case history([ChatEventRecord])
    case terminal(seq: Int, data: Data)
    case agentStatus(AgentStatus)
    case codexCatalog(CodexCatalog)
    case decisions([Decision])
    case attached([String])         // the paths of the files just attached, in the shared folder (spec §4 of 0.7)
    case changes([BotChange])
    case diagnostics(Diagnostics)
    case error(String)
}

/// An unsolicited update from the engine to the app.
public enum Push: Codable, Equatable, Sendable {
    case botChanged(BotSummary)
    case projectChanged(Project)
    case chatEvent(botId: UUID, record: ChatEventRecord)
    case requestOpened(PendingRequest)
    case requestClosed(requestId: UUID, botId: UUID, resolution: RequestResolution, answer: RequestAnswer? = nil)
    case terminalOutput(botId: UUID, seq: Int, data: Data)
    case routinesChanged(projectId: UUID, routines: [Routine])     // the project's whole list (spec §4 of 0.6)
}

/// Every line the engine writes: either a response to a request or a push.
public enum EngineMessage: Codable, Equatable, Sendable {
    case response(id: Int, body: ResponseBody)
    case push(Push)
}

public enum SerifProtocol { public static let version = 1 }

/// Encoder for the app-engine protocol: ISO-8601 dates with fractional seconds, base64 data, one line per message.
public func protocolEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(makeISOFormatter(fractional: true).string(from: date))
    }
    encoder.dataEncodingStrategy = .base64
    return encoder
}

/// Decoder matching `protocolEncoder()`. It also accepts dates without fractional seconds.
public func protocolDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        if let date = makeISOFormatter(fractional: true).date(from: text)
            ?? makeISOFormatter(fractional: false).date(from: text) {
            return date
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "Invalid ISO-8601 date: \(text)"))
    }
    return decoder
}

// A new formatter per call: ISO8601DateFormatter is not Sendable, so it is never shared.
private func makeISOFormatter(fractional: Bool) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    return formatter
}

// serif-hook <-> engine (hook.sock)
public struct HookEnvelope: Codable, Equatable, Sendable {
    public let botId: String
    public let token: String
    public let payload: JSONValue

    public init(botId: String, token: String, payload: JSONValue) {
        self.botId = botId
        self.token = token
        self.payload = payload
    }
}

/// `stdout` is what the hook prints back to Claude; nil means print nothing.
public struct HookReply: Codable, Equatable, Sendable {
    public let stdout: String?

    public init(stdout: String?) { self.stdout = stdout }
}
