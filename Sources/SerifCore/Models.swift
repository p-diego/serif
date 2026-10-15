import Foundation

/// Which coding agent runs a bot.
public enum Agent: String, Codable, CaseIterable, Sendable {
    case claude, codex
}

/// How much a bot may do without asking.
public enum Freedom: String, Codable, CaseIterable, Sendable {
    case ask, edits, auto

    /// The value passed to `claude --permission-mode`.
    public var claudePermissionMode: String {
        switch self {
        case .ask: "manual"
        case .edits: "acceptEdits"
        case .auto: "auto"
        }
    }
}

/// A group of bots that share a folder for files.
public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var linkedFolder: String?
    public var readLinkedInstructions: Bool
    public var archivedAt: Date?
    /// Skill folders and plugin ids every bot of the project gets (spec §6.1 of 0.3): `plugins` are Claude Code's,
    /// `codexPlugins` Codex's ("name@marketplace"), since the two apps' plugins differ (spec §6).
    public var skills: [String]
    public var plugins: [String]
    public var codexPlugins: [String]
    /// The project's lead (spec §8): gets a copy of every finished task; nil when the project has none.
    public var leadBotId: UUID?

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), linkedFolder: String? = nil,
                readLinkedInstructions: Bool = true, archivedAt: Date? = nil, skills: [String] = [], plugins: [String] = [],
                codexPlugins: [String] = [], leadBotId: UUID? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.linkedFolder = linkedFolder
        self.readLinkedInstructions = readLinkedInstructions
        self.archivedAt = archivedAt
        self.skills = skills
        self.plugins = plugins
        self.codexPlugins = codexPlugins
        self.leadBotId = leadBotId
    }

    // A state.json from before 0.3 has no lists, from before 0.4 no Codex plugins, from before 0.5 no lead: the project
    // starts without them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        linkedFolder = try c.decodeIfPresent(String.self, forKey: .linkedFolder)
        readLinkedInstructions = try c.decode(Bool.self, forKey: .readLinkedInstructions)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        plugins = try c.decodeIfPresent([String].self, forKey: .plugins) ?? []
        codexPlugins = try c.decodeIfPresent([String].self, forKey: .codexPlugins) ?? []
        leadBotId = try c.decodeIfPresent(UUID.self, forKey: .leadBotId)
    }
}

/// A chat bot: one agent session inside a project, with its own face and settings.
public struct Bot: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var face: BotFace
    public var agent: Agent
    public var model: String?
    public var instructions: String
    public var freedom: Freedom
    public var sessionId: UUID
    public var notifications: Bool
    public var pinned: Bool
    public var createdAt: Date
    public var archivedAt: Date?
    /// Skill folders linked into the bot's folder, plugin ids, and whether claude.ai's connectors reach it (spec §6.1).
    public var skills: [String]
    public var plugins: [String]
    public var connectors: Bool
    /// A Codex bot's thread, saved once its first turn started (a thread without turns cannot be resumed, spec §3.5);
    /// nil before that and for Claude Code bots, whose conversation is `sessionId`.
    public var threadId: String?
    /// The bot that created this one with its tools (spec §7); nil for a bot the user created.
    public var createdBy: UUID?

    public init(id: UUID = UUID(), projectId: UUID, name: String, face: BotFace, agent: Agent = .claude,
                model: String? = nil, instructions: String = "", freedom: Freedom = .ask, sessionId: UUID = UUID(),
                notifications: Bool = true, pinned: Bool = false, createdAt: Date = Date(), archivedAt: Date? = nil,
                skills: [String] = [], plugins: [String] = [], connectors: Bool = false, threadId: String? = nil,
                createdBy: UUID? = nil) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.face = face
        self.agent = agent
        self.model = model
        self.instructions = instructions
        self.freedom = freedom
        self.sessionId = sessionId
        self.notifications = notifications
        self.pinned = pinned
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.skills = skills
        self.plugins = plugins
        self.connectors = connectors
        self.threadId = threadId
        self.createdBy = createdBy
    }

    // A state.json from before 0.3: no skills or plugins, connectors off (the author's choice, spec §6.1 of 0.3); from
    // before 0.4: no thread; from before 0.5: no creator.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        name = try c.decode(String.self, forKey: .name)
        face = try c.decode(BotFace.self, forKey: .face)
        agent = try c.decode(Agent.self, forKey: .agent)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        instructions = try c.decode(String.self, forKey: .instructions)
        freedom = try c.decode(Freedom.self, forKey: .freedom)
        sessionId = try c.decode(UUID.self, forKey: .sessionId)
        notifications = try c.decode(Bool.self, forKey: .notifications)
        pinned = try c.decode(Bool.self, forKey: .pinned)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        plugins = try c.decodeIfPresent([String].self, forKey: .plugins) ?? []
        connectors = try c.decodeIfPresent(Bool.self, forKey: .connectors) ?? false
        threadId = try c.decodeIfPresent(String.self, forKey: .threadId)
        createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
    }
}
