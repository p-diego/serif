import Foundation
import SerifCore

// A bot's changes (spec §5–6 of 0.7): the one place a bot is saved after its creation, the history line per field it
// writes there, and what each change does to the running bot.
extension Engine {
    /// The sheet, `update_instructions`, Restore and the agent switch all come here. Saves the bot, writes one history
    /// line per changed field, tells the apps; new instructions wait for the bot's next message (spec §6), a new model,
    /// freedom, skills, plugins or connectors restart it — unless `relaunch` is off, when the caller starts it itself,
    /// or a stop or an agent switch is under way: the launch that follows picks the new fields up (spec §7 of 0.7).
    func saveBot(_ bot: Bot, by author: ChangeAuthor, _ rt: BotRuntime, relaunch: Bool = true) throws {
        let changes = botChanges(from: rt.bot, to: bot, by: author, at: now())
        try store.save(bot: bot)                 // memory changes only once the disk has it
        rt.bot = bot
        for change in changes {
            do { try store.append(change, bot: bot.id) } catch { log("history of \(bot.id) not written: \(error)") }
        }
        push(.botChanged(rt.summary))
        let fields = Set(changes.map(\.field))
        if fields.contains(.instructions) {
            rt.instructionsPending = true
            record(.system(.instructionsChanged(by: author.botName)), rt)
        }
        if relaunch, !rt.stopping, rt.pendingAgent == nil,
           !fields.isDisjoint(with: [.model, .freedom, .skills, .plugins, .connectors]) { restart(rt) }
    }
}

extension ChangeAuthor {
    /// The bot's name for a change a bot made; nil for yours.
    var botName: String? { if case let .bot(_, name) = self { name } else { nil } }
}
