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
