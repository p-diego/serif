import Foundation

// The history of a bot's changes (spec §5 of 0.7): one line per changed field in `bots/<id>/history.jsonl`, written
// by the engine where the bot is saved; the app shows them and puts a value back with "Restore".

/// Who changed the bot: you, or a bot with its tools (`update_instructions`), named as it was then.
public enum ChangeAuthor: Codable, Equatable, Sendable {
    case user
    case bot(id: UUID, name: String)
}

/// The fields the history follows (spec §5), in the sheet's order.
public enum BotField: String, Codable, CaseIterable, Sendable {
    case name, face, instructions, model, freedom, skills, plugins, connectors, agent, notifications
}

/// One change: the field's value before and after, as JSON (a face is an object, a list a list, the model text or null).
public struct BotChange: Codable, Equatable, Sendable {
    public var at: Date
    public var by: ChangeAuthor
    public var field: BotField
    public var old: JSONValue
    public var new: JSONValue

    public init(at: Date, by: ChangeAuthor, field: BotField, old: JSONValue, new: JSONValue) {
        self.at = at; self.by = by; self.field = field; self.old = old; self.new = new
    }
}

/// A bot's value of `field`, as the history keeps it.
public func fieldValue(_ bot: Bot, _ field: BotField) -> JSONValue {
    switch field {
    case .name: .string(bot.name)
    case .face: (try? JSONValue.parse(JSONEncoder().encode(bot.face))) ?? .null
    case .instructions: .string(bot.instructions)
    case .model: bot.model.map(JSONValue.string) ?? .null
    case .freedom: .string(bot.freedom.rawValue)
    case .skills: .array(bot.skills.map(JSONValue.string))
    case .plugins: .array(bot.plugins.map(JSONValue.string))
    case .connectors: .bool(bot.connectors)
    case .agent: .string(bot.agent.rawValue)
    case .notifications: .bool(bot.notifications)
    }
}

/// The changes from `old` to `new`, field by field (spec §5): none for a bot saved as it was.
public func botChanges(from old: Bot, to new: Bot, by: ChangeAuthor, at: Date) -> [BotChange] {
    BotField.allCases.compactMap { field in
        let (before, after) = (fieldValue(old, field), fieldValue(new, field))
        return before == after ? nil : BotChange(at: at, by: by, field: field, old: before, new: after)
    }
}

/// `bot` with the change's old value back in its field ("Restore", spec §5); nil when the value does not fit the field.
public func restoring(_ change: BotChange, into bot: Bot) -> Bot? {
    var b = bot
    let v = change.old
    switch change.field {
    case .name: guard let s = v.string else { return nil }; b.name = s
    case .face:
        guard let data = try? v.encoded(), let face = try? JSONDecoder().decode(BotFace.self, from: data) else {
            return nil
        }
        b.face = face
    case .instructions: guard let s = v.string else { return nil }; b.instructions = s
    case .model: if v == .null { b.model = nil } else if let s = v.string { b.model = s } else { return nil }
    case .freedom: guard let f = v.string.flatMap(Freedom.init(rawValue:)) else { return nil }; b.freedom = f
    case .skills: guard let list = v.array?.compactMap(\.string) else { return nil }; b.skills = list
    case .plugins: guard let list = v.array?.compactMap(\.string) else { return nil }; b.plugins = list
    case .connectors: guard let on = v.bool else { return nil }; b.connectors = on
    case .agent: guard let a = v.string.flatMap(Agent.init(rawValue:)) else { return nil }; b.agent = a
    case .notifications: guard let on = v.bool else { return nil }; b.notifications = on
    }
    return b
}
