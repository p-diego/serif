import Foundation
import SerifCore

// serifd.sock: the app's requests (spec §3.7). Every request gets one response with its id; pushes go to every app.
extension Engine {
    func appConnected(_ connection: LineConnection) {
        let key = ObjectIdentifier(connection)
        apps[key] = (connection, [])
        connection.onLine = { [weak self] line in self?.appLine(line, from: connection) }
        connection.onClose = { [weak self] in
            guard let self else { return }
            let shown = apps.removeValue(forKey: key)?.terminals ?? []
            shown.compactMap { self.bots[$0] }.forEach(terminalViewersChanged)
        }
    }

    private func appLine(_ line: Data, from connection: LineConnection) {
        guard let envelope = try? decoder.decode(RequestEnvelope.self, from: line) else {
            log("unreadable app request")
            struct JustId: Decodable { let id: Int }
            if let id = try? decoder.decode(JustId.self, from: line).id {
                send(.response(id: id, body: .error("Unreadable request")), to: [connection])
            }
            return
        }
        // "Quit and stop the bots": answered once every bot has stopped, then the process exits 0 (launchd leaves it down).
        if case .shutdown = envelope.request {
            return shutdown { [weak self] in
                self?.send(.response(id: envelope.id, body: .ok), to: [connection])
                exit(0)
            }
        }
        // An agent's check runs off the queue: answered once it is done.
        if case let .agentStatus(agent) = envelope.request {
            return checkAgent(agent) { [weak self] status in
                self?.send(.response(id: envelope.id, body: .agentStatus(status)), to: [connection])
            }
        }
        if case .codexCatalog = envelope.request {
            return codexCatalog { [weak self] catalog in
                self?.send(.response(id: envelope.id, body: catalog.map(ResponseBody.codexCatalog) ?? .error("Codex did not answer")),
                           to: [connection])
            }
        }
        // The new agent is checked first (spec §7 of 0.7): missing or signed out, the switch is refused with its problem.
        if case let .changeAgent(botId, agent) = envelope.request {
            return checkAgent(agent) { [weak self] status in
                guard let self else { return }
                var body = ResponseBody.ok
                if let problem = status.problem { body = .error(problem.rawValue) }
                else {
                    do { try changeAgent(try runtime(botId), to: agent) }
                    catch { body = .error((error as? Refusal)?.reason ?? "\(error)") }
                }
                send(.response(id: envelope.id, body: body), to: [connection])
            }
        }
        // Both agents are checked anew, so the page says how they are now (spec §8 of 0.7); read-only (no bot is relaunched
        // by it) and bounded: past `diagnosticsBound` the last known statuses stand.
        if case .diagnostics = envelope.request {
            let checks = DispatchGroup()
            var answered = false
            let answer = { [weak self] in
                guard let self, !answered else { return }
                answered = true
                send(.response(id: envelope.id, body: .diagnostics(diagnostics())), to: [connection])
            }
            for agent in Agent.allCases { checks.enter(); checkAgent(agent, relaunching: false) { _ in checks.leave() } }
            checks.notify(queue: queue, execute: answer)
            return queue.asyncAfter(deadline: .now() + diagnosticsBound, execute: answer)
        }
        let body: ResponseBody
        do { body = try respond(to: envelope.request, from: connection) } catch {
            body = .error((error as? Refusal)?.reason ?? "\(error)")
        }
        send(.response(id: envelope.id, body: body), to: [connection])
    }

    private func respond(to request: AppRequest, from connection: LineConnection) throws -> ResponseBody {
        switch request {
        case .hello:
            return .welcome(protocolVersion: SerifProtocol.version, engineVersion: SerifEngineVersion.current)
        case .snapshot:
            return .snapshot(Snapshot(projects: store.projects, bots: store.bots.compactMap { bots[$0.id]?.summary },
                                      requests: requests.values.map(\.request).sorted { $0.openedAt < $1.openedAt },
                                      routines: store.projects.flatMap { store.routines($0.id) },
                                      engineVersion: SerifEngineVersion.current))
        case let .createProject(name, linkedFolder, readLinkedInstructions):
            let project = Project(name: name, linkedFolder: linkedFolder, readLinkedInstructions: readLinkedInstructions)
            try FileManager.default.createDirectory(at: paths.shared(project.id), withIntermediateDirectories: true)
            try store.save(project: project)
            push(.projectChanged(project))
            return .project(project)
        case let .updateProject(project):
            guard let old = store.projects.first(where: { $0.id == project.id }) else { throw Refusal("Unknown project") }
            // The lead is one of the project's active bots, or none (spec §8); choosing one restarts nobody.
            if let lead = project.leadBotId, lead != old.leadBotId,
               !store.bots.contains(where: { $0.id == lead && $0.projectId == project.id && $0.archivedAt == nil }) {
                throw Refusal("The lead must be an active bot of this project")
            }
            try store.save(project: project)
            push(.projectChanged(project))
            // --add-dir, the linked instructions, skills and plugins come from the project: relaunch its bots when those
            // change. A new name reaches system.md at their next launch.
            let shared = (project.linkedFolder, project.readLinkedInstructions, project.skills)
                != (old.linkedFolder, old.readLinkedInstructions, old.skills)
            for rt in bots.values where rt.bot.projectId == project.id {
                // Each agent has its own list of plugins (spec §6).
                let plugins = rt.bot.agent == .codex ? project.codexPlugins != old.codexPlugins : project.plugins != old.plugins
                if shared || plugins { restart(rt) }
            }
            return .project(project)
        case let .archiveProject(id):
            guard var project = store.projects.first(where: { $0.id == id }) else { throw Refusal("Unknown project") }
            project.archivedAt = Date()
            try store.save(project: project)
            for rt in bots.values where rt.bot.projectId == id && rt.bot.archivedAt == nil { try archive(rt) }
            push(.projectChanged(project))
            return .ok
        case let .createBot(new):
            return .bot(try createBot(new))
        case let .updateBot(update):
            let rt = try runtime(update.id)
            var bot = update
            // The engine owns the conversation id, Codex's thread, the agent (changed only by `changeAgent`, spec §7 of
            // 0.7), the archive flag, the creation date (the app's copy went through JSON with millisecond dates: compared
            // as is, a bot created in this engine run always looked changed) and the creator (spec §7 of 0.5).
            (bot.sessionId, bot.threadId, bot.agent, bot.archivedAt, bot.createdAt, bot.createdBy) =
                (rt.bot.sessionId, rt.bot.threadId, rt.bot.agent, rt.bot.archivedAt, rt.bot.createdAt, rt.bot.createdBy)
            // Built for the other agent (the app's copy predates a switch done since): its model and plugins are not
            // this agent's and stay as the switch left them (spec §7 of 0.7).
            if update.agent != rt.bot.agent { (bot.model, bot.plugins) = (rt.bot.model, rt.bot.plugins) }
            try saveBot(bot, by: .user, rt)          // the history, the restart or the instructions notice (spec §5–6 of 0.7)
            return .bot(bot)
        case let .archiveBot(id):
            try archive(try runtime(id))
            return .ok
        case let .restartBot(id):
            restart(try runtime(id))
            return .ok
        case let .history(botId, beforeSeq, limit):
            return .history(try store.history(bot: botId, beforeSeq: beforeSeq, limit: limit))
        case let .send(botId, text, attachments):
            let rt = try runtime(botId)
            // Only paths `attach` gave: in the shared folder's allegati/, never above it.
            if let bad = attachments?.first(where: { !$0.hasPrefix(AttachmentRules.folder + "/") || ($0 as NSString).pathComponents.contains("..") }) {
                throw Refusal("Unknown attachment \(bad)")
            }
            let message = Outgoing(text: text, origin: .chat, attachments: attachments)
            if rt.bot.agent == .codex {
                if case .stopped = rt.tracker.state { throw Refusal("The bot is archived") }
                // A new turn, or added to the running one; while its server starts, once it is ready (spec §4).
                rt.outbox.append(message)
                deliverCodex(rt)
                return .ok
            }
            if rt.stopping { rt.outbox.append(message); return .ok }  // restart window: the relaunch's SessionStart delivers it
            switch rt.tracker.state {
            case .starting, .crashed: rt.outbox.append(message)       // delivered on the next SessionStart
            case .stopped: throw Refusal("The bot is archived")
            default:
                // Enter would answer an open dialog ("Yes", approve the plan, option A): the text waits for the bot's last
                // request to close, and behind texts already waiting so the order holds.
                if hasOpenRequest(rt) || !rt.outbox.isEmpty { rt.outbox.append(message) }
                else { type(text, attachments: attachments, into: rt) }
            }
            return .ok
        case let .attach(botId, files):
            // The files go into the shared folder under today's allegati/ (spec §4 of 0.7), each with a name no file there
            // has; a file that cannot be written refuses the whole message (spec §10): the app sends nothing then.
            let rt = try runtime(botId)
            if let problem = attachmentProblem(files.map { ($0.name, $0.data.count) }) { throw Refusal(problem) }
            let folder = attachmentFolder(day: now())
            let dir = paths.shared(rt.bot.projectId).appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])   // compared without case
            var saved: [String] = []
            for file in files {
                let name = uniqueFileName(safeFileName(file.name), taken: taken)
                // Last guard: never over a file that is there (APFS ignores case); a failure is the clear error.
                do { try file.data.write(to: dir.appendingPathComponent(name), options: .withoutOverwriting) }
                catch { throw Refusal("Could not save \(name)") }
                taken.insert(name)
                saved.append("\(folder)/\(name)")
            }
            return .attached(saved)
        case let .changes(botId):
            _ = try runtime(botId)
            return .changes(store.changes(bot: botId))
        case let .interrupt(botId):
            stopTurn(try runtime(botId))
            return .ok
        case let .answer(requestId, answer):
            return try self.answer(requestId, answer)
        case let .cancelTask(projectId, number):
            do { try cancelTask(number, in: projectId, by: nil, reason: nil) }
            catch let refusal as MailError { throw Refusal(refusal.text) }
            return .ok
        case let .saveRoutine(routine):
            try saveRoutine(routine)
            return .ok
        case let .deleteRoutine(id):
            try deleteRoutine(id)
            return .ok
        case let .runRoutine(id):
            try runRoutineNow(id)
            return .ok
        case let .decisions(projectId):
            guard store.projects.contains(where: { $0.id == projectId }) else { throw Refusal("Unknown project") }
            return .decisions(store.mailbox(projectId).decisions)
        case let .markRead(botId, seq):
            let rt = try runtime(botId)
            updateMeta(rt) { $0.lastReadSeq = max($0.lastReadSeq, seq) }
            // From the first record: whether the mail started a turn is told by its start (spec §6).
            rt.unread = isUnread(lastReadSeq: store.meta(botId).lastReadSeq,
                                 records: try store.records(bot: botId, afterSeq: 0))
            push(.botChanged(rt.summary))
            return .ok
        case let .attachTerminal(botId):
            let rt = try runtime(botId)
            // Codex shows a thread in its terminal only once it has a turn (spec §3.5): the app shows a placeholder.
            if rt.bot.agent == .codex, rt.bot.threadId == nil { throw Refusal(CodexText.terminalNotYet) }
            apps[ObjectIdentifier(connection)]?.terminals.insert(botId)
            terminalViewersChanged(rt)
            let replay = rt.host.replay()
            return .terminal(seq: replay.seq, data: replay.data)
        case let .detachTerminal(botId):
            apps[ObjectIdentifier(connection)]?.terminals.remove(botId)
            if let rt = bots[botId] { terminalViewersChanged(rt) }
            return .ok
        case let .terminalInput(botId, data):
            try runtime(botId).host.write(Array(data))
            return .ok
        case let .resizeTerminal(botId, cols, rows):
            try runtime(botId).host.resize(cols: cols, rows: rows)
            return .ok
        case .agentStatus, .codexCatalog, .changeAgent, .diagnostics:
            return .ok      // never reached: appLine answers them once the agents' checks are done
        case .shutdown:
            return .ok      // never reached: appLine answers it after the bots have stopped
        }
    }

    func runtime(_ id: UUID) throws -> BotRuntime {
        guard let rt = bots[id] else { throw Refusal("Unknown bot") }
        return rt
    }

    /// The first answer wins: from the app here, or from the terminal (the request is then already closed).
    private func answer(_ requestId: UUID, _ answer: RequestAnswer) throws -> ResponseBody {
        guard let open = requests[requestId], let rt = bots[open.request.botId] else { throw Refusal("The request is already closed") }
        switch open.asker {
        case .engine:
            // A decision (spec §6 of 0.6): the answer goes to the bot as mail from you, the card closes.
            guard case let .decision(option, text) = answer else { throw Refusal("This answer does not fit the request") }
            do { try answerDecision(open.request, option: option, text: text) }
            catch let refusal as MailError { throw Refusal(refusal.text) }
        case let .codex(id):
            guard let result = codexReply(for: answer, request: open.request) else { throw Refusal("This answer does not fit the request") }
            guard let server = rt.codex else { throw Refusal("The bot is not running") }
            server.respond(to: id, result: result)
        case let .hook(hook):
            switch hookOutcome(for: answer, request: open.request) {
            case let .reply(json):
                reply(hook, json)
            case .silent:
                throw Refusal("This answer does not fit the request")
            case let .typeInTerminal(keys):
                // Plan approval does not go through the hook: release it, then press the key. Without the plan question
                // on screen the key would land in the prompt, so the request stays open for the terminal.
                guard screenSignals(in: rt.host.screenText).contains(.planApproval) else { throw Refusal("Answer in the terminal") }
                reply(hook, nil)
                rt.host.write(Array(keys.utf8))
            }
        }
        closeRequest(requestId, .answeredInApp, replied: true, answer: answer)
        return .ok
    }
}
