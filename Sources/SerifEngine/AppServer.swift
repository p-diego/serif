import Foundation
import SerifCore

// serifd.sock: the app's requests (spec §3.7). Every request gets one response with its id; pushes go to every app.
extension Engine {
    func appConnected(_ connection: LineConnection) {
        let key = ObjectIdentifier(connection)
        apps[key] = (connection, [])
        connection.onLine = { [weak self] line in self?.appLine(line, from: connection) }
        connection.onClose = { [weak self] in self?.apps[key] = nil }
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
        // Claude Code's check runs off the queue: answered once it is done.
        if case .claudeStatus = envelope.request {
            return checkClaude { [weak self] status in
                self?.send(.response(id: envelope.id, body: .claudeStatus(status)), to: [connection])
            }
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
                                      engineVersion: SerifEngineVersion.current))
        case let .createProject(name, linkedFolder, readLinkedInstructions):
            let project = Project(name: name, linkedFolder: linkedFolder, readLinkedInstructions: readLinkedInstructions)
            try FileManager.default.createDirectory(at: paths.shared(project.id), withIntermediateDirectories: true)
            try store.save(project: project)
            push(.projectChanged(project))
            return .project(project)
        case let .updateProject(project):
            guard let old = store.projects.first(where: { $0.id == project.id }) else { throw Refusal("Unknown project") }
            try store.save(project: project)
            push(.projectChanged(project))
            // The system prompt, --add-dir, skills and plugins come from the project: relaunch its bots when those change.
            if (project.name, project.linkedFolder, project.readLinkedInstructions, project.skills, project.plugins)
                != (old.name, old.linkedFolder, old.readLinkedInstructions, old.skills, old.plugins) {
                bots.values.filter { $0.bot.projectId == project.id }.forEach(restart)
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
            guard store.projects.contains(where: { $0.id == new.projectId }) else { throw Refusal("Unknown project") }
            let bot = Bot(projectId: new.projectId, name: new.name, face: new.face, agent: new.agent, model: new.model,
                          instructions: new.instructions, freedom: new.freedom, skills: new.skills, plugins: new.plugins,
                          connectors: new.connectors)
            try store.save(bot: bot)
            let rt = addRuntime(bot)
            push(.botChanged(rt.summary))          // the app knows the bot before its first chat event
            record(.system(.botCreated), rt)
            launch(rt)
            return .bot(bot)
        case let .updateBot(update):
            let rt = try runtime(update.id)
            var bot = update
            // The engine owns the conversation id, the archive flag and the creation date (the app's copy went through
            // JSON with millisecond dates: compared as is, a bot created in this engine run always looked changed).
            (bot.sessionId, bot.archivedAt, bot.createdAt) = (rt.bot.sessionId, rt.bot.archivedAt, rt.bot.createdAt)
            // Model, instructions, freedom, skills, plugins and connectors relaunch the bot (spec §4.5 of 0.1, §6.2); the rest
            // waits for the next launch (a new name or project reaches system.md and the folders then) or never reaches
            // Claude Code at all.
            var launchFields = bot
            (launchFields.face, launchFields.pinned, launchFields.notifications, launchFields.name, launchFields.projectId) =
                (rt.bot.face, rt.bot.pinned, rt.bot.notifications, rt.bot.name, rt.bot.projectId)
            let relaunch = launchFields != rt.bot
            try store.save(bot: bot)
            rt.bot = bot
            push(.botChanged(rt.summary))
            if relaunch { restart(rt) }
            return .bot(bot)
        case let .archiveBot(id):
            try archive(try runtime(id))
            return .ok
        case let .restartBot(id):
            restart(try runtime(id))
            return .ok
        case let .history(botId, beforeSeq, limit):
            return .history(try store.history(bot: botId, beforeSeq: beforeSeq, limit: limit))
        case let .send(botId, text):
            let rt = try runtime(botId)
            if rt.stopping { rt.outbox.append(text); return .ok }  // restart window: the relaunch's SessionStart delivers it
            switch rt.tracker.state {
            case .starting, .crashed: rt.outbox.append(text)       // delivered on the next SessionStart
            case .stopped: throw Refusal("The bot is archived")
            default:
                // Enter would answer an open dialog ("Yes", approve the plan, option A): the text waits for the bot's last
                // request to close, and behind texts already waiting so the order holds.
                if hasOpenRequest(rt) || !rt.outbox.isEmpty { rt.outbox.append(text) } else { type(text, into: rt) }
            }
            return .ok
        case let .interrupt(botId):
            try runtime(botId).host.pressEscape()
            return .ok
        case let .answer(requestId, answer):
            return try self.answer(requestId, answer)
        case let .markRead(botId, seq):
            let rt = try runtime(botId)
            updateMeta(rt) { $0.lastReadSeq = max($0.lastReadSeq, seq) }
            let lastRead = store.meta(botId).lastReadSeq
            rt.unread = isUnread(lastReadSeq: lastRead, records: try store.records(bot: botId, afterSeq: lastRead))
            push(.botChanged(rt.summary))
            return .ok
        case let .attachTerminal(botId):
            let replay = try runtime(botId).host.replay()
            apps[ObjectIdentifier(connection)]?.terminals.insert(botId)
            return .terminal(seq: replay.seq, data: replay.data)
        case let .detachTerminal(botId):
            apps[ObjectIdentifier(connection)]?.terminals.remove(botId)
            return .ok
        case let .terminalInput(botId, data):
            try runtime(botId).host.write(Array(data))
            return .ok
        case let .resizeTerminal(botId, cols, rows):
            try runtime(botId).host.resize(cols: cols, rows: rows)
            return .ok
        case .claudeStatus:
            return .ok      // never reached: appLine answers it once the check is done
        case .shutdown:
            return .ok      // never reached: appLine answers it after the bots have stopped
        }
    }

    private func runtime(_ id: UUID) throws -> BotRuntime {
        guard let rt = bots[id] else { throw Refusal("Unknown bot") }
        return rt
    }

    /// The first answer wins: from the app here, or from the terminal (the request is then already closed).
    private func answer(_ requestId: UUID, _ answer: RequestAnswer) throws -> ResponseBody {
        guard let open = requests[requestId], let rt = bots[open.request.botId] else { throw Refusal("The request is already closed") }
        switch hookOutcome(for: answer, request: open.request) {
        case let .reply(json):
            reply(open.hook, json)
        case .silent:
            throw Refusal("This answer does not fit the request")
        case let .typeInTerminal(keys):
            // Plan approval does not go through the hook: release it, then press the key. Without the plan question
            // on screen the key would land in the prompt, so the request stays open for the terminal.
            guard screenSignals(in: rt.host.screenText).contains(.planApproval) else { throw Refusal("Answer in the terminal") }
            reply(open.hook, nil)
            rt.host.write(Array(keys.utf8))
        }
        closeRequest(requestId, .answeredInApp, replied: true, answer: answer)
        return .ok
    }
}
