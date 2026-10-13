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
    /// Codex is missing or does not answer within 20 s.
    func codexCatalog(then: @escaping (CodexCatalog?) -> Void) {
        if let fresh = freshCodexCatalog { return then(fresh) }
        codexCatalogWaiters.append(then)
        guard codexCatalogWaiters.count == 1 else { return }
        var done = false        // this reading answers once: by its server, or by its time limit
        let finish = { [weak self] (catalog: CodexCatalog?) in
            guard let self, !done else { return }
            done = true
            if let catalog { codexCatalogRead = (catalog, Date()) }
            let waiters = codexCatalogWaiters
            codexCatalogWaiters = []
            waiters.forEach { $0(catalog) }
        }
        let read = { [weak self] (status: AgentStatus) in
            guard let self else { return }
            guard status.problem == nil, let path = status.path else { return finish(nil) }
            let server = CodexServer(queue: queue)
            let token = codexToken()
            let deadline = Date().addingTimeInterval(20)
            queue.asyncAfter(deadline: .now() + 20) { server.stop {}; finish(nil) }
            server.start(CodexServer.Launch(executable: path, args: { codexServerArgs(listen: "ws://127.0.0.1:\($0)", tokenHash: codexTokenHash(token)) },
                                            environment: codexEnvironment(environment), cwd: paths.root.path, token: token,
                                            log: paths.root.appendingPathComponent("codex-catalog.log"))) { [weak self] failure in
                guard let self, failure == nil else { server.stop {}; return finish(nil) }
                readCodexCatalog(server, deadline: deadline) { catalog in server.stop {}; finish(catalog) }
            }
        }
        if let known = statuses[.codex], known.problem == nil { read(known) } else { checkAgent(.codex, then: read) }
    }

    private func readCodexCatalog(_ server: CodexServer, deadline: Date, then: @escaping (CodexCatalog) -> Void) {
        server.request("plugin/list", [:]) { [weak self] plugins in
            server.request("model/list", [:]) { models in
                func skills() {
                    server.request("skills/list", [:]) { list in
                        let catalog = CodexCatalog(pluginList: try? plugins.get(), skillList: try? list.get(), modelList: try? models.get())
                        // The remote plugins' skills come some seconds after the start, with no notice (spec §3.7): asked again.
                        // ponytail: one question a second; a remote plugin with no skills makes it wait for the deadline.
                        if catalog.remotePlugins.contains(where: { catalog.remoteSkills[$0] == nil }), Date() < deadline {
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
}
