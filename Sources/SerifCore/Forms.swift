import Foundation

public func canCreateProject(name: String) -> Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
public func canCreateBot(name: String, projectId: UUID?) -> Bool { projectId != nil && canCreateProject(name: name) }

/// The model choices of the bot editor, mapped to `claude --model` values (nil = the CLI default).
public enum BotModel: CaseIterable, Sendable {
    case standard, opus, sonnet, haiku
    public var value: String? {
        switch self {
        case .standard: nil
        case .opus: "opus"
        case .sonnet: "sonnet"
        case .haiku: "haiku"
        }
    }
    public init(value: String?) { self = Self.allCases.first { $0.value == value } ?? .standard }
}

/// Project preselected in the new-bot sheet: the one of the selected bot, else the first.
public func defaultProjectId(projects: [Project], selectedBotProject: UUID?) -> UUID? {
    if let p = selectedBotProject, projects.contains(where: { $0.id == p }) { return p }
    return projects.first?.id
}

private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {   // splitmix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The scattered mascots of the empty state: distinct faces from a fixed seed, so the screen is always the same.
public func emptyStateFaces(count: Int) -> [BotFace] {
    var rng = SeededRNG(state: 20261012)
    var faces: [BotFace] = []
    for _ in 0..<count { faces.append(randomFace(existing: faces, using: &rng)) }
    return faces
}

/// The fields the bot editor changes; everything else (session, pin, archive state) stays as the live bot has it.
public struct BotEdits: Equatable, Sendable {
    public var name: String, face: BotFace, model: String?, instructions: String, freedom: Freedom, notifications: Bool
    public var skills: [String], plugins: [String], connectors: Bool
    public init(name: String, face: BotFace, model: String?, instructions: String, freedom: Freedom, notifications: Bool,
                skills: [String], plugins: [String], connectors: Bool) {
        self.name = name; self.face = face; self.model = model; self.instructions = instructions
        self.freedom = freedom; self.notifications = notifications
        self.skills = skills; self.plugins = plugins; self.connectors = connectors
    }
}

extension Bot {
    /// This (live) bot with the editor's fields applied.
    public func applying(_ edits: BotEdits) -> Bot {
        var bot = self
        bot.name = edits.name; bot.face = edits.face; bot.model = edits.model
        bot.instructions = edits.instructions; bot.freedom = edits.freedom; bot.notifications = edits.notifications
        bot.skills = edits.skills; bot.plugins = edits.plugins; bot.connectors = edits.connectors
        return bot
    }
}
