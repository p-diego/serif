import Foundation
import SerifCore

// Diagnostics (spec §8 of 0.7): the page's data, from what the engine already keeps.
extension Engine {
    /// The agents as last checked (`appLine` checks both first), every live bot with its last crash, the mail waiting
    /// for it, its routines and their next run, its open cards, and the log's last 100 lines. No secret is in any of it:
    /// the tokens never reach the log (and a token-shaped string is cut from its tail), and the chats' texts are not read.
    func diagnostics() -> Diagnostics {
        let agents = Agent.allCases.map { agent -> AgentDiagnostics in
            let s = statuses[agent]
            return AgentDiagnostics(agent: agent, path: s?.path, version: s?.version, signedIn: s?.loggedIn)
        }
        let bots = store.bots.filter { $0.archivedAt == nil }.compactMap { bot -> BotDiagnostics? in
            guard let rt = self.bots[bot.id] else { return nil }
            let routines = store.routines(bot.projectId).filter { $0.botId == bot.id }.map {
                BotDiagnostics.RoutineNext(name: $0.name, next: $0.enabled ? nextRun(of: $0, notBefore: routineFloor) : nil)
            }
            let project = store.projects.first { $0.id == bot.projectId }?.name ?? "?"
            return BotDiagnostics(name: bot.name, project: project, agent: bot.agent, state: rt.tracker.state,
                                  lastCrash: store.meta(bot.id).lastCrash, mailWaiting: store.mailbox(bot.projectId).waiting(for: bot.id).count,
                                  routines: routines, openCards: requests.values.filter { $0.request.botId == bot.id }.count)
        }
        // ponytail: the whole log is read for its tail; seek from the end if it ever grows past a few MB.
        let log = (try? String(contentsOf: paths.log, encoding: .utf8)) ?? ""
        // The live secrets by value too: a Claude Code bot's launch token is a UUID, not token-shaped.
        let secrets = self.bots.values.flatMap { [$0.token, $0.codexToken] }.filter { !$0.isEmpty }
        let tail = log.split(separator: "\n", omittingEmptySubsequences: true).suffix(100)
            .map { line in secrets.reduce(redacted(String(line))) { $0.replacingOccurrences(of: $1, with: "[redacted]") } }
        return Diagnostics(appVersion: "", engineVersion: SerifEngineVersion.current, dataFolder: paths.root.path,
                           agents: agents, bots: bots, logTail: tail)
    }
}

/// A backstop for the log's tail: a 64-hex token, `Bearer …` and `SERIF_TOKEN=…` are replaced, whatever logged them.
func redacted(_ line: String) -> String {
    line.replacingOccurrences(of: #"[0-9a-fA-F]{64}|Bearer\s+\S+|SERIF_TOKEN=\S+"#, with: "[redacted]", options: .regularExpression)
}
