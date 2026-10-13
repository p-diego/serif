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

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), linkedFolder: String? = nil,
                readLinkedInstructions: Bool = true, archivedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.linkedFolder = linkedFolder
        self.readLinkedInstructions = readLinkedInstructions
        self.archivedAt = archivedAt
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

    public init(id: UUID = UUID(), projectId: UUID, name: String, face: BotFace, agent: Agent = .claude,
                model: String? = nil, instructions: String = "", freedom: Freedom = .ask, sessionId: UUID = UUID(),
                notifications: Bool = true, pinned: Bool = false, createdAt: Date = Date(), archivedAt: Date? = nil) {
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
    }
}
