import Foundation
import SerifCore

// Codex bots (spec §4): one private app-server per bot, a thread on it, its chat from the server's events, its real
// terminal only while an app shows it.
extension Engine {
    // MARK: - Catalog

    /// The catalog read less than 5 minutes ago, if any.
    var freshCodexCatalog: CodexCatalog? {
        codexCatalogRead.flatMap { $0.at.timeIntervalSinceNow > -300 ? $0.catalog : nil }
    }

    /// Codex's installed plugins, the skills of its remote ones and its models (spec §6), from a short-lived server of the
    /// engine's (the same kind a bot gets, with no bot); kept 5 minutes. Calls made while one is read share it; nil when
    /// Codex is missing, does not answer (20 s) or fails the plugin list, or the engine is stopping. Nil is never kept.
    func codexCatalog(then: @escaping (CodexCatalog?) -> Void) {
        guard !stopping else { return then(nil) }
        if let fresh = freshCodexCatalog { return then(fresh) }
        codexCatalogWaiters.append(then)
        guard codexCatalogWaiters.count == 1 else { return }
        var done = false        // this reading answers once: by its server, or by its time limit
        var hardLimit: DispatchWorkItem?
        let finish = { [weak self] (catalog: CodexCatalog?) in
            guard let self, !done else { return }
            done = true
            hardLimit?.cancel()
            codexCatalogServer?.stop {}
            codexCatalogServer = nil
            codexCatalogFinish = nil
            if let catalog { codexCatalogRead = (catalog, Date()) }
            let waiters = codexCatalogWaiters
            codexCatalogWaiters = []
            waiters.forEach { $0(catalog) }
        }
        codexCatalogFinish = finish
        let read = { [weak self] (status: AgentStatus) in
            guard let self, !done else { return }
            guard !stopping, status.problem == nil, let path = status.path else { return finish(nil) }
            let server = CodexServer(queue: queue)
            codexCatalogServer = server
            let token = codexToken()
            let deadline = Date().addingTimeInterval(codexCatalogPollLimit)
            hardLimit = DispatchWorkItem { finish(nil) }
            queue.asyncAfter(deadline: .now() + codexCatalogHardLimit, execute: hardLimit!)
            server.start(CodexServer.Launch(executable: path, args: { codexServerArgs(listen: "ws://127.0.0.1:\($0)", tokenHash: codexTokenHash(token)) },
                                            environment: codexEnvironment(environment), cwd: paths.root.path, token: token,
                                            log: paths.root.appendingPathComponent("codex-catalog.log"),
                                            pidFile: paths.root.appendingPathComponent("codex-catalog.pid"))) { [weak self] failure in
                guard let self, !done else { return }
                guard failure == nil else { return finish(nil) }
                readCodexCatalog(server, deadline: deadline, then: finish)
            }
        }
        if let known = statuses[.codex], known.problem == nil { read(known) } else { checkAgent(.codex, then: read) }
    }

    /// nil when `plugin/list` fails; a failed `model/list` leaves no models, a failed `skills/list` ends the asking.
    private func readCodexCatalog(_ server: CodexServer, deadline: Date, then: @escaping (CodexCatalog?) -> Void) {
        server.request("plugin/list", [:]) { [weak self] plugins in
            guard let pluginList = try? plugins.get() else { return then(nil) }
            server.request("model/list", [:]) { models in
                func skills() {
                    server.request("skills/list", [:]) { list in
                        let skillList = try? list.get()
                        let catalog = CodexCatalog(pluginList: pluginList, skillList: skillList, modelList: try? models.get())
                        // The remote plugins' skills come some seconds after the start, with no notice (spec §3.7): asked again
                        // until the poll limit, then what is known is handed over.
                        // ponytail: one question a second; a remote plugin with no skills makes it wait for the limit.
                        if skillList != nil, catalog.remotePlugins.contains(where: { catalog.remoteSkills[$0] == nil }), Date() < deadline {
                            self?.queue.asyncAfter(deadline: .now() + 1) { skills() }
                            return
                        }
                        then(catalog)
                    }
                }
                skills()
            }
        }
    }

    // MARK: - Launch

    /// Starts a Codex bot (spec §4): its skills linked, its own server with the switches of §6, then its thread (opened or
    /// resumed with every setting again), the isolation check, and whatever waits in its outbox. The whole start has
    /// `codexStartupTimeout` (spec §8).
    func launchCodex(_ rt: BotRuntime, project: Project, codexPath: String, catalog: CodexCatalog, instructions: String,
                     linkedExists: Bool) {
        let bot = rt.bot, workspace = paths.bot(bot.id).workspace
        // Codex does not read the project's folder for skills: the project's go into the bot's folder too (spec §6), once
        // when both chose one.
        var seen = Set<String>()
        for problem in linkSkills((bot.skills + project.skills).filter { seen.insert($0).inserted }, into: workspace, under: ".agents/skills") {
            log("bot \(bot.id): \(problem)")
        }
        let chosen = Set(bot.plugins + project.codexPlugins)
        chosen.subtracting(catalog.plugins.map(\.id)).sorted().forEach { log("bot \(bot.id): Codex plugin \($0) not found, left out") }
        let plugins = catalog.plugins.filter { !catalog.remotePlugins.contains($0.id) }.map { (id: $0.id, enabled: chosen.contains($0.id)) }
        let hidden = catalog.remotePlugins.filter { !chosen.contains($0) }.flatMap { catalog.remoteSkills[$0] ?? [] }
        let token = codexToken()
        rt.token = UUID().uuidString                    // the tools' secret, new at every start (spec §4)
        var environment = codexEnvironment(environment)
        environment["SERIF_BOT_ID"] = bot.id.uuidString
        environment["SERIF_TOKEN"] = rt.token
        environment["SERIF_HOOK_SOCKET"] = paths.hookSocket.path
        let server = CodexServer(queue: queue)          // a new one at every start: nothing of an earlier one carries over
        (rt.codex, rt.codexToken, rt.codexReady, rt.thread, rt.turnId) = (server, token, false, nil, nil)
        (rt.sending, rt.interruptPending, rt.settingsRestored) = (false, false, false)
        rt.codexNormalizer = CodexNormalizer()
        rt.launchedAt = Date()
        server.onMessage = { [weak self, weak rt] message in if let rt { self?.codexMessage(message, rt) } }
        server.onExit = { [weak self, weak rt] code in if let rt { self?.codexExited(rt, reason: "Exit code \(code)") } }
        rt.tracker.processStarted()
        push(.botChanged(rt.summary))
        let watchdog = DispatchWorkItem { [weak self, weak rt] in
            guard let rt, rt.codex === server, !rt.codexReady else { return }
            self?.codexExited(rt, reason: CodexText.notStarted)
        }
        rt.startup = watchdog
        queue.asyncAfter(deadline: .now() + codexStartupTimeout, execute: watchdog)
        let roots = [workspace.path, paths.shared(project.id).path] + (linkedExists ? [project.linkedFolder!] : [])
        rt.turnPolicies = codexTurnPolicies(freedom: bot.freedom, writableRoots: roots)
        // "Default" is Codex's default model: a thread that ran on another one goes back to it.
        let model = bot.model ?? catalog.models.first(where: \.isDefault)?.id
        let params = { (resume: String?) in
            codexThreadParams(resume: resume, cwd: workspace.path, model: model, instructions: instructions, freedom: bot.freedom,
                              writableRoots: roots)
        }
        let files = paths.bot(bot.id)
        server.start(CodexServer.Launch(executable: codexPath,
                                        args: { [toolsCommand] port in
                                            codexServerArgs(listen: "ws://127.0.0.1:\(port)",
                                                            tokenHash: codexTokenHash(token), tools: toolsCommand,
                                                            plugins: plugins, hiddenSkills: hidden,
                                                            connectors: bot.connectors)
                                        },
                                        environment: environment, cwd: workspace.path, token: token,
                                        log: files.dir.appendingPathComponent("codex.log"),
                                        pidFile: files.dir.appendingPathComponent("codex.pid"))) { [weak self, weak rt] failure in
            guard let self, let rt, rt.codex === server else { return }
            guard let failure else { return openThread(rt, server, params: params) }
            // Codex's own refusal is Codex answering differently (spec §8): retrying won't help.
            if failure.fromCodex { codexStopped(rt, reason: "Codex: \(failure.message)") } else { codexExited(rt, reason: failure.message) }
        }
    }

    private func openThread(_ rt: BotRuntime, _ server: CodexServer, params: @escaping (String?) -> JSONValue) {
        let resume = rt.bot.threadId
        server.request(resume == nil ? "thread/start" : "thread/resume", params(resume)) { [weak self, weak rt] result in
            guard let self, let rt, rt.codex === server else { return }
            switch result {
            case let .failure(f) where f.fromCodex && resume != nil && f.message.contains("no rollout found"):
                // The thread is gone from Codex (archived, deleted): a new conversation, as when Claude Code cannot resume.
                rt.bot.threadId = nil
                do { try store.save(bot: rt.bot) } catch { log("cannot save \(rt.bot.id): \(error)") }
                record(.system(.newConversation), rt)
                openThread(rt, server, params: params)
            case let .failure(f):
                if f.fromCodex { codexStopped(rt, reason: "Codex: \(f.message)") }        // a Codex that answers differently (spec §8)
            case let .success(answer):
                guard let thread = answer["thread"]?["id"]?.string else { return codexStopped(rt, reason: "Codex: no thread") }
                rt.thread = thread
                checkIsolation(rt, server, thread: thread) { [weak self, weak rt] in if let rt { self?.codexReady(rt, resumed: resume != nil) } }
            }
        }
    }

    /// The thread must report Siigil's hooks off and, with the bot's connectors off, no `codex_apps` (spec §4, §8); a bot
    /// that cannot show it never runs, and stops if it no longer does. `then` runs once it has shown it.
    private func checkIsolation(_ rt: BotRuntime, _ server: CodexServer, thread: String, then: @escaping () -> Void) {
        server.request("experimentalFeature/list", ["threadId": .string(thread), "limit": 500]) { [weak self, weak rt] features in
            guard let self, let rt else { return }
            if rt.bot.connectors { return isolationChecked(rt, server, features: features, mcp: nil, then: then) }
            server.request("mcpServerStatus/list", ["threadId": .string(thread), "detail": "toolsAndAuthOnly", "limit": 500]) { [weak self, weak rt] mcp in
                guard let self, let rt else { return }
                isolationChecked(rt, server, features: features, mcp: mcp, then: then)
            }
        }
    }

    private func isolationChecked(_ rt: BotRuntime, _ server: CodexServer, features: Result<JSONValue, CodexServer.Failure>,
                                  mcp: Result<JSONValue, CodexServer.Failure>?, then: () -> Void) {
        guard rt.codex === server else { return }
        // Lost on the way: the server's exit, or the start's time limit, decides.
        if case let .failure(f) = features, !f.fromCodex { return }
        if case let .failure(f)? = mcp, !f.fromCodex { return }
        if let problem = codexIsolationProblem(features: try? features.get(), mcpServers: try? mcp?.get(), connectors: rt.bot.connectors) {
            log("bot \(rt.bot.id): \(CodexText.isolation): \(problem)")
            return codexStopped(rt, reason: CodexText.isolation)
        }
        // Without its tools a bot still runs (spec §10): the log says so.
        if let servers = try? mcp?.get(), let problem = codexToolsProblem(servers) {
            log("bot \(rt.bot.id): \(problem)")
        }
        then()
    }

    private func codexReady(_ rt: BotRuntime, resumed: Bool) {
        rt.startup?.cancel()
        rt.startup = nil
        rt.codexReady = true
        rt.tracker.sessionStarted()
        push(.botChanged(rt.summary))
        if resumed { record(.system(.resumed), rt) }
        deliverCodex(rt)
        deliverMail(rt)                 // mail that waited while it was down (spec §6)
        terminalViewersChanged(rt)      // an app that kept the terminal open across a restart
    }

    // MARK: - Ending

    /// The server is gone (it exited, or was stopped): its terminal goes too; a turn cut short closes as interrupted and
    /// its cards as cancelled, as for Claude Code.
    func codexEnded(_ rt: BotRuntime) {
        let turn = rt.turnId
        rt.startup?.cancel()
        (rt.codex, rt.codexReady, rt.thread, rt.turnId, rt.startup) = (nil, false, nil, nil, nil)
        (rt.sending, rt.interruptPending, rt.settingsRestored) = (false, false, false)
        stopTerminal(rt)
        closeRequests(of: rt, .cancelled)
        // Closed as Codex closes one it interrupts: what had streamed of the reply stays in the chat. A routine's run
        // cut so has failed, unless the engine was already stopping it (spec §4 of 0.6).
        guard rt.tracker.state.inTurn else { return }
        if rt.run != nil { rt.runEnding = rt.runEnding ?? .failed }
        let end: JSONValue = ["turn": ["id": turn.map(JSONValue.string) ?? .null, "status": "interrupted"]]
        handle(rt.codexNormalizer.ingest(.notification(method: "turn/completed", params: end)), rt)
    }

    /// A crash (spec §8): the server exited by itself, or did not start or get ready in time. The bot starts again after
    /// the usual wait and resumes its thread.
    func codexExited(_ rt: BotRuntime, reason: String) {
        let ranFor = Date().timeIntervalSince(rt.launchedAt)
        let server = rt.codex
        server?.onExit = nil
        codexEnded(rt)
        server?.stop {}
        guard !rt.stopping, !stopping else { return }
        crashedRelaunching(rt, reason: reason, ranFor: ranFor)
    }

    /// The bot must not run as it is (isolation not shown, Codex answering differently): stopped with `reason` in the chat
    /// and the log, until Restart (spec §8).
    func codexStopped(_ rt: BotRuntime, reason: String) {
        log("bot \(rt.bot.id): stopped: \(reason)")
        let server = rt.codex
        server?.onExit = nil
        codexEnded(rt)
        server?.stop {}
        record(.system(.crashed(reason: reason)), rt)
        crashed(rt, reason)
    }

    // MARK: - Conversation

    /// Sends what waits in the outbox, in order (spec §4): a new turn when none runs, added to the running one otherwise.
    /// One text at a time: the next waits for the answer to the one on its way (a new turn's id, or the steer's).
    func deliverCodex(_ rt: BotRuntime) {
        guard rt.codexReady, !rt.sending, !rt.outbox.isEmpty else { return }
        let message = rt.outbox.removeFirst()
        let noticed = rt.instructionsPending
        let sent = outgoingText(message, rt)
        rt.codexNormalizer.expectChatMessage(sent, origin: message.origin, shown: sent == message.text ? nil : message.text,
                                             attachments: message.attachments)
        sendTurn(message, sent: sent, noticed: noticed, to: rt, steering: rt.turnId)
    }

    /// A text whose request never left (its server is going: restarted, crashed) goes back to the front of the outbox, for
    /// the next launch, with the instructions notice it carried (`noticed`) due again. One that left and got no answer is
    /// not sent again, Codex may have taken it: the chat says so.
    private func sendTurn(_ message: Outgoing, sent: String, noticed: Bool, to rt: BotRuntime, steering turn: String?) {
        let back = { rt.outbox.insert(message, at: 0); if noticed { rt.instructionsPending = true } }
        guard let server = rt.codex, let thread = rt.thread else { return back() }
        let input = codexInput(text: sent, attachments: message.attachments ?? [],
                               sharedFolder: paths.shared(rt.bot.projectId).path)
        let params: [String: JSONValue] = turn.map { ["threadId": .string(thread), "expectedTurnId": .string($0), "input": input] }
            ?? rt.turnPolicies.merging(["threadId": .string(thread), "input": input]) { $1 }
        rt.sending = true
        server.request(turn == nil ? "turn/start" : "turn/steer", .object(params)) { [weak self, weak rt] result in
            guard let self, let rt else { return }
            rt.sending = false
            switch result {
            case let .success(answer):
                if turn == nil { rt.turnId = rt.turnId ?? answer["turn"]?["id"]?.string }
            case let .failure(f) where f.fromCodex && turn != nil:
                // The turn ended before the steer: the text opens a new one, still ahead of the others.
                if rt.turnId == turn { rt.turnId = nil }
                back()
            case let .failure(f) where f.fromCodex:
                record(.turnFailed(reason: "Codex: \(f.message)"), rt)
            case let .failure(f) where f.neverSent:
                return back()
            case .failure:
                return record(.system(.messageMayNotHaveArrived(text: sent)), rt)
            }
            if rt.interruptPending { interruptCodex(rt) }
            deliverCodex(rt)
        }
    }

    /// Stop (spec §4): the running turn is interrupted; one whose turn/start is still on its way, as soon as it has an id.
    func interruptCodex(_ rt: BotRuntime) {
        guard let server = rt.codex, let thread = rt.thread, let turn = rt.turnId else {
            rt.interruptPending = rt.sending && rt.turnId == nil
            return
        }
        rt.interruptPending = false
        server.request("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)]) { [weak self, weak rt] result in
            guard let self, let rt, case let .failure(f) = result, f.fromCodex else { return }
            log("bot \(rt.bot.id): turn/interrupt refused: \(f.message)")
        }
    }

    /// One message of the bot's server, in order: the running turn and the thread kept, then the chat and the cards.
    func codexMessage(_ message: CodexMessage, _ rt: BotRuntime) {
        // Another thread on this server (the terminal's /new or /resume) is not the bot's: its events, turns and requests
        // are left to the terminal.
        switch message {
        case let .notification(_, p), let .request(_, _, p):
            if let thread = p["threadId"]?.string, thread != rt.thread { return }
        case .response, .failure: break
        }
        var finished = false
        if case let .notification(method, p) = message {
            switch method {
            case "turn/started":
                rt.turnId = p["turn"]?["id"]?.string
                saveThread(rt)
                if rt.interruptPending { interruptCodex(rt) }
            case "turn/completed":
                if rt.turnId == p["turn"]?["id"]?.string { rt.turnId = nil }
                // Cards still open when a turn stops short are gone; after a normal end `record` closes them.
                if p["turn"]?["status"]?.string != "completed" { closeRequests(of: rt, .cancelled) }
                finished = true
            case "mcpServer/startupStatus/updated":
                guard p["name"]?.string == "serif", p["status"]?.string == "failed" else { break }
                log("bot \(rt.bot.id): Serif's tools failed to start: \(p["error"]?.string ?? "no reason given")")
            case "thread/settings/updated":
                // The terminal can change the thread's settings: whatever changed, the isolation must still show, and the
                // bot's approval and sandbox go back (spec §5). Still not the bot's right after that: the bot stops.
                guard let server = rt.codex, let thread = rt.thread else { break }
                checkIsolation(rt, server, thread: thread) {}
                guard codexSettingsDrift(p["threadSettings"], policies: rt.turnPolicies) else { rt.settingsRestored = false; break }
                let reported = ["approvalPolicy", "sandboxPolicy"].map { p["threadSettings"]?[$0]?.compactText ?? "-" }
                if rt.settingsRestored {
                    log("bot \(rt.bot.id): settings still not the bot's after restoring them: \(reported)")
                    codexStopped(rt, reason: CodexText.isolation)
                    return
                }
                log("bot \(rt.bot.id): settings changed to \(reported): the bot's again")
                rt.settingsRestored = true
                server.request("thread/settings/update", .object(rt.turnPolicies.merging(["threadId": .string(thread)]) { $1 })) { [weak self, weak rt] in
                    if case let .failure(f) = $0, let rt { self?.log("bot \(rt.bot.id): settings not restored: \(f.message)") }
                }
            default: break
            }
        }
        let outputs = rt.codexNormalizer.ingest(message)
        handle(outputs, rt)
        // A request Serif shows no card for is refused, so the turn does not wait forever (spec §8).
        if case let .request(id, method, _) = message, !outputs.contains(where: { if case .serverRequest = $0 { true } else { false } }) {
            log("bot \(rt.bot.id): Codex asked \(method): not supported, refused")
            rt.codex?.refuse(id, message: "Serif does not support \(method)")
        }
        if finished { deliverCodex(rt) }
    }

    /// A thread can be resumed, and shown in the terminal, once it has a turn (spec §3.5): saved then, never before.
    private func saveThread(_ rt: BotRuntime) {
        guard let thread = rt.thread, rt.bot.threadId != thread else { return }
        rt.bot.threadId = thread
        do { try store.save(bot: rt.bot) } catch { log("cannot save the thread of \(rt.bot.id): \(error)") }
        push(.botChanged(rt.summary))
        terminalViewersChanged(rt)
    }

    // MARK: - Terminal

    /// A Codex bot's real terminal runs only while some app shows it (spec §4): started for the first view once the thread
    /// has a turn and the server is ready, stopped after the last view.
    func terminalViewersChanged(_ rt: BotRuntime) {
        guard rt.bot.agent == .codex else { return }
        guard apps.values.contains(where: { $0.terminals.contains(rt.bot.id) }) else {
            // Only a running one: `stopTerminal` looks again here once it has gone, and a host already stopped calls back at
            // once, so without this check the two would call each other forever.
            if rt.host.isRunning { stopTerminal(rt) }
            return
        }
        // Never on a server being stopped (its next launch's `codexReady` asks again); the server's own Codex, since
        // `statuses` forgets it while any Codex bot is crashed.
        guard !rt.host.isRunning, !rt.stopping, rt.codexReady, let thread = rt.bot.threadId, let server = rt.codex,
              let path = server.launch?.executable else { return }
        rt.host.start(codexTerminalPlan(codexPath: path, threadId: thread, port: server.port, token: rt.codexToken,
                                        cwd: paths.bot(rt.bot.id).workspace.path, baseEnvironment: environment))
    }

    /// Stops the terminal, and looks again once it has gone: shown again meanwhile, or its server relaunched and ready
    /// before it went, it starts anew. One that exits by itself stays closed until shown again.
    private func stopTerminal(_ rt: BotRuntime) { rt.host.stop { [weak self] in self?.terminalViewersChanged(rt) } }

    /// The Codex servers an engine that died (SIGKILL, a crash) left running, from their pid files: stopped like any other
    /// (SIGTERM, SIGKILL after 3 s). A pid reused since by another program, another `codex app-server` (the ChatGPT app's,
    /// an editor's) included, is left alone: only the process with the recorded secret's hash is Serif's.
    func stopLeftoverCodexServers() {
        let bots = paths.root.appendingPathComponent("bots")
        let files = [paths.root.appendingPathComponent("codex-catalog.pid")]
            + ((try? FileManager.default.contentsOfDirectory(atPath: bots.path)) ?? []).map { bots.appendingPathComponent("\($0)/codex.pid") }
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            try? FileManager.default.removeItem(at: file)
            let parts = text.split(separator: " ").map(String.init)
            guard parts.count == 2, let pid = pid_t(parts[0]), runsCodexServer(pid, tokenHash: parts[1]) else { continue }
            log("stopping Codex server \(pid), left running by an earlier engine")
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if runsCodexServer(pid, tokenHash: parts[1]) { kill(pid, SIGKILL) } }
        }
    }
}

/// `pid` runs the server started with `--ws-token-sha256 <tokenHash>`: the hash of a secret only that launch had.
private func runsCodexServer(_ pid: pid_t, tokenHash: String) -> Bool {
    let words = AgentCheck.output("/bin/ps", ["-o", "command=", "-p", "\(pid)"], [:])?.split(whereSeparator: \.isWhitespace) ?? []
    return zip(words, words.dropFirst()).contains { $0 == "--ws-token-sha256" && $1 == tokenHash }
}
