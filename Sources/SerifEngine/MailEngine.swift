import Foundation
import SerifCore

// The bots' own tools (spec §4): calls from serif-tools on hook.sock, answered at once.
extension Engine {
    /// A call of `rt`'s Serif tools; the answer is a text the model reads (spec §4).
    func handleTool(_ name: String, _ arguments: JSONValue, from rt: BotRuntime) -> ToolResult {
        switch name {
        case "list_bots": return ToolResult(listBots(for: rt))
        default: return ToolResult("Serif has no tool called \(name)", isError: true)
        }
    }

    /// `list_bots` (spec §4), with the project's lead as it is now (spec §8).
    private func listBots(for rt: BotRuntime) -> String {
        let lead = store.projects.first { $0.id == rt.bot.projectId }?.leadBotId
        let mates = projectBots(rt).map { ($0, bots[$0.id]?.tracker.state ?? .stopped) }
        return colleaguesText(mates, caller: rt.bot.id, lead: lead)
    }

    /// The project's bots, archived ones too (names resolve against all of them, spec §4).
    func projectBots(_ rt: BotRuntime) -> [Bot] { store.bots.filter { $0.projectId == rt.bot.projectId } }
}
