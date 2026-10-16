import Foundation
import SerifCore

// A bot moved from Claude Code to Codex or back (spec §7 of 0.7): a new conversation on the other agent, its memory
// file renamed, plugins and model reset; instructions, skills, connectors, freedom, mail, routines and decisions kept.
extension Engine {
    /// The app's request. Refused for an archived bot or one never started; the same agent is nothing to do. The switch
    /// is done by the bot's next launch (`switchAgent`), one rule for the three waits: a restart now, the end of the
    /// running turn (`turnOver`), or the relaunch after a crash. The new agent was checked by the caller (`appLine`).
    func changeAgent(_ rt: BotRuntime, to agent: Agent) throws {
        guard rt.bot.archivedAt == nil else { throw Refusal("The bot is archived") }
        guard agent != rt.bot.agent else { rt.pendingAgent = nil; return }       // changed their mind: nothing waits
        guard store.meta(rt.bot.id).hasStarted else { throw Refusal("The bot has not started yet") }
        rt.pendingAgent = agent
        if !rt.tracker.state.inTurn { restart(rt) }
    }

    /// The pending switch, once the old agent's process is gone (`launch`): the bot saved on the new agent, its
    /// conversation, plugins and model forgotten, its memory moved; the history gets the change, the chat its line.
    /// False when the bot could not be saved (logged, nothing else touched: the next launch tries again). A memory that
    /// cannot be moved is logged and left.
    func switchAgent(_ rt: BotRuntime, to agent: Agent) -> Bool {
        var bot = rt.bot
        (bot.agent, bot.model, bot.plugins, bot.sessionId, bot.threadId) = (agent, nil, [], UUID(), nil)
        do { try saveBot(bot, by: .user, rt, relaunch: false) }                   // saved first: no half state
        catch { log("cannot save \(rt.bot.id): \(error)"); return false }
        rt.pendingAgent = nil
        if let problem = moveMemory(in: paths.bot(rt.bot.id).workspace, to: agent) {
            log("bot \(rt.bot.id): \(problem)")
        }
        updateMeta(rt) { $0.hasStarted = false }            // a new conversation: no --resume
        record(.system(.agentChanged(agent)), rt)
        return true
    }
}

/// `CLAUDE.md` becomes `AGENTS.md` or back (spec §7); with both there, the new agent's stays and the other becomes
/// `<name>.old.md` (an older `.old.md` is replaced). The problem when the move failed, else nil.
func moveMemory(in workspace: URL, to agent: Agent) -> String? {
    let (old, new) = agent == .codex ? ("CLAUDE.md", "AGENTS.md") : ("AGENTS.md", "CLAUDE.md")
    let fm = FileManager.default
    let from = workspace.appendingPathComponent(old)
    guard fm.fileExists(atPath: from.path) else { return nil }
    let bothThere = fm.fileExists(atPath: workspace.appendingPathComponent(new).path)
    let to = workspace.appendingPathComponent(bothThere ? old.replacingOccurrences(of: ".md", with: ".old.md") : new)
    do {
        if bothThere { try? fm.removeItem(at: to) }
        try fm.moveItem(at: from, to: to)
    } catch { return "memory \(old) not moved: \(error.localizedDescription)" }
    return nil
}
