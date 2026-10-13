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
            guard status.problem == nil, let path = status.path else { return finish(nil) }
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
    /// resumed with every setting again) and the isolation check. The whole start has `codexStartupTimeout` (spec §8).
    func launchCodex(_ rt: BotRuntime, project: Project, codexPath: String, instructions: String, linkedExists: Bool) {
        guard let catalog = freshCodexCatalog else { return }
        let bot = rt.bot, workspace = paths.bot(bot.id).workspace
        // Codex does not read the project's folder for skills: the project's go into the bot's folder too (spec §6).
        for problem in linkSkills(bot.skills + project.skills, into: workspace, under: ".agents/skills") {
            log("bot \(bot.id): \(problem)")
        }
        let chosen = Set(bot.plugins + project.codexPlugins)
        chosen.subtracting(catalog.plugins.map(\.id)).sorted().forEach { log("bot \(bot.id): Codex plugin \($0) not found, left out") }
        let plugins = catalog.plugins.filter { !catalog.remotePlugins.contains($0.id) }.map { (id: $0.id, enabled: chosen.contains($0.id)) }
        let hidden = catalog.remotePlugins.filter { !chosen.contains($0) }.flatMap { catalog.remoteSkills[$0] ?? [] }
        let token = codexToken()
        let server = CodexServer(queue: queue)          // a new one at every start: nothing of an earlier one carries over
        (rt.codex, rt.codexToken, rt.codexReady, rt.thread, rt.turnId, rt.turnStarting) = (server, token, false, nil, nil, false)
        rt.codexNormalizer = CodexNormalizer()
        rt.launchedAt = Date()
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
        // "Default" is Codex's default model: a thread that ran on another one goes back to it.
        let model = bot.model ?? catalog.models.first(where: \.isDefault)?.id
        let params = { (resume: String?) in
            codexThreadParams(resume: resume, cwd: workspace.path, model: model, instructions: instructions, freedom: bot.freedom,
                              writableRoots: roots)
        }
        let files = paths.bot(bot.id)
        server.start(CodexServer.Launch(executable: codexPath,
                                        args: { codexServerArgs(listen: "ws://127.0.0.1:\($0)", tokenHash: codexTokenHash(token), plugins: plugins,
                                                                hiddenSkills: hidden, connectors: bot.connectors) },
                                        environment: codexEnvironment(environment), cwd: workspace.path, token: token,
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
                checkIsolation(rt, server, thread: thread, resumed: resume != nil)
            }
        }
    }

    /// The thread must report Siigil's hooks off and, with the bot's connectors off, no `codex_apps` (spec §4, §8); a bot
    /// that cannot show it never runs.
    private func checkIsolation(_ rt: BotRuntime, _ server: CodexServer, thread: String, resumed: Bool) {
        server.request("experimentalFeature/list", ["threadId": .string(thread), "limit": 500]) { [weak self, weak rt] features in
            guard let self, let rt else { return }
            if rt.bot.connectors { return isolationChecked(rt, server, features: features, mcp: nil, resumed: resumed) }
            server.request("mcpServerStatus/list", ["threadId": .string(thread), "detail": "toolsAndAuthOnly", "limit": 500]) { [weak self, weak rt] mcp in
                guard let self, let rt else { return }
                isolationChecked(rt, server, features: features, mcp: mcp, resumed: resumed)
            }
        }
    }

    private func isolationChecked(_ rt: BotRuntime, _ server: CodexServer, features: Result<JSONValue, CodexServer.Failure>,
                                  mcp: Result<JSONValue, CodexServer.Failure>?, resumed: Bool) {
        guard rt.codex === server else { return }
        // Lost on the way: the server's exit, or the start's time limit, decides.
        if case let .failure(f) = features, !f.fromCodex { return }
        if case let .failure(f)? = mcp, !f.fromCodex { return }
        if let problem = codexIsolationProblem(features: try? features.get(), mcpServers: try? mcp?.get(), connectors: rt.bot.connectors) {
            log("bot \(rt.bot.id): \(CodexText.isolation): \(problem)")
            return codexStopped(rt, reason: CodexText.isolation)
        }
        codexReady(rt, resumed: resumed)
    }

    private func codexReady(_ rt: BotRuntime, resumed: Bool) {
        rt.startup?.cancel()
        rt.startup = nil
        rt.codexReady = true
        rt.tracker.sessionStarted()
        push(.botChanged(rt.summary))
        if resumed { record(.system(.resumed), rt) }
    }

    // MARK: - Ending

    /// The server is gone (it exited, or was stopped): its terminal goes too; a turn cut short closes as interrupted and
    /// its cards as cancelled, as for Claude Code.
    func codexEnded(_ rt: BotRuntime) {
        rt.startup?.cancel()
        (rt.codex, rt.codexReady, rt.thread, rt.turnId, rt.turnStarting, rt.startup) = (nil, false, nil, nil, false, nil)
        rt.host.stop {}
        closeRequests(of: rt, .cancelled)
        if rt.tracker.state.inTurn { record(.turnInterrupted, rt) }
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

    /// The Codex servers an engine that died (SIGKILL, a crash) left running, from their pid files: stopped like any other
    /// (SIGTERM, SIGKILL after 3 s). A pid reused since by another program is left alone.
    func stopLeftoverCodexServers() {
        let bots = paths.root.appendingPathComponent("bots")
        let files = [paths.root.appendingPathComponent("codex-catalog.pid")]
            + ((try? FileManager.default.contentsOfDirectory(atPath: bots.path)) ?? []).map { bots.appendingPathComponent("\($0)/codex.pid") }
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            try? FileManager.default.removeItem(at: file)
            guard let pid = pid_t(text), isCodexServer(pid) else { continue }
            log("stopping Codex server \(pid), left running by an earlier engine")
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if isCodexServer(pid) { kill(pid, SIGKILL) } }
        }
    }
}

/// `pid` runs `codex … app-server` (and is not a pid reused since by another program).
private func isCodexServer(_ pid: pid_t) -> Bool {
    let words = AgentCheck.output("/bin/ps", ["-o", "command=", "-p", "\(pid)"], [:])?.split(whereSeparator: \.isWhitespace) ?? []
    guard let server = words.firstIndex(of: "app-server") else { return false }
    return words[..<server].contains { $0.split(separator: "/").last?.contains("codex") == true }
}
