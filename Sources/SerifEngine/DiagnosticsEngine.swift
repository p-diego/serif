import Foundation
import SerifCore

// Diagnostics (spec §8 of 0.7): the page's data, from what the engine already keeps.
extension Engine {
    /// The agents as last checked (`appLine` checks both first), every live bot with its last crash, the mail waiting
    /// for it, its routines and their next run, its open cards, and the log's last 100 lines. No secret is in any of it:
    /// the tokens never reach the log, and the chats' texts are not read.
    func diagnostics() -> Diagnostics {
        let agents = Agent.allCases.map { agent -> AgentDiagnostics in
            let s = statuses[agent]
            return AgentDiagnostics(agent: agent, path: s?.path, version: s?.version, signedIn: s?.loggedIn)
        }
        let bots = store.bots.filter { $0.archivedAt == nil }.compactMap { bot -> BotDiagnostics? in
            guard let rt = self.bots[bot.id] else { return nil }
            let crash = ((try? store.records(bot: bot.id, afterSeq: 0)) ?? []).last {
                if case .system(.crashed) = $0.event { true } else { false }
            }
            var lastCrash: BotDiagnostics.Crash?
            if let crash, case let .system(.crashed(reason)) = crash.event {
                lastCrash = .init(at: crash.at, reason: reason)
            }
            let routines = store.routines(bot.projectId).filter { $0.botId == bot.id }.map {
                BotDiagnostics.RoutineNext(name: $0.name, next: $0.enabled ? nextRun(of: $0, notBefore: routineFloor) : nil)
            }
            let project = store.projects.first { $0.id == bot.projectId }?.name ?? "?"
            return BotDiagnostics(name: bot.name, project: project, agent: bot.agent, state: rt.tracker.state,
                                  lastCrash: lastCrash, mailWaiting: store.mailbox(bot.projectId).waiting(for: bot.id).count,
                                  routines: routines, openCards: requests.values.filter { $0.request.botId == bot.id }.count)
        }
        // ponytail: the whole log is read for its tail; seek from the end if it ever grows past a few MB.
        let log = (try? String(contentsOf: paths.log, encoding: .utf8)) ?? ""
        let tail = log.split(separator: "\n", omittingEmptySubsequences: true).suffix(100).map(String.init)
        return Diagnostics(appVersion: "", engineVersion: SerifEngineVersion.current, dataFolder: paths.root.path,
                           agents: agents, bots: bots, logTail: tail)
    }
}
