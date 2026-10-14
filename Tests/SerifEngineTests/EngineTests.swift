import XCTest
import SerifCore
@testable import SerifEngine

/// A test app: connects to serifd.sock, sends requests and records every message, all on its own queue.
final class TestClient {
    let queue = DispatchQueue(label: "engine-test-client")
    private let conn: LineConnection
    private var messages: [EngineMessage] = []
    private var watchers: [(([EngineMessage]) -> Bool, XCTestExpectation)] = []
    private var nextId = 0

    init?(path: String) {
        guard let c = LineClient.connect(path: path, queue: queue) else { return nil }
        conn = c
        queue.sync {
            c.onLine = { [unowned self] line in
                guard let m = try? protocolDecoder().decode(EngineMessage.self, from: line) else { return }
                messages.append(m)
                check()
            }
        }
    }

    var all: [EngineMessage] { queue.sync { messages } }

    func close() { queue.sync { conn.close() } }

    /// An expectation fulfilled once `condition` holds for the messages received so far.
    func expectation(_ description: String, _ condition: @escaping ([EngineMessage]) -> Bool) -> XCTestExpectation {
        let e = XCTestExpectation(description: description)
        queue.sync { watchers.append((condition, e)); check() }
        return e
    }

    /// Sends a request; returns an expectation for its response and the id to look it up.
    func send(_ request: AppRequest) -> (XCTestExpectation, Int) {
        let id: Int = queue.sync { nextId += 1; return nextId }
        let line = try! protocolEncoder().encode(RequestEnvelope(id: id, request: request))
        let e = expectation("response \(id)") { $0.contains { if case .response(id, _) = $0 { true } else { false } } }
        queue.sync { conn.send(line) }
        return (e, id)
    }

    func response(_ id: Int) -> ResponseBody? {
        all.lazy.compactMap { if case let .response(rid, body) = $0, rid == id { body } else { nil } }.first
    }

    private func check() {
        watchers.removeAll { condition, e in
            guard condition(messages) else { return false }
            e.fulfill()
            return true
        }
    }
}

// Helpers reading the recorded messages.
extension [EngineMessage] {
    var pushes: [Push] { compactMap { if case let .push(p) = $0 { p } else { nil } } }

    func chatEvents(_ bot: UUID) -> [ChatEvent] {
        pushes.compactMap { if case let .chatEvent(id, record) = $0, id == bot { record.event } else { nil } }
    }

    func summaries(_ bot: UUID) -> [BotSummary] {
        pushes.compactMap { if case let .botChanged(s) = $0, s.bot.id == bot { s } else { nil } }
    }

    /// The terminal replay plus every later output push, in arrival order.
    var terminalText: String {
        let chunks: [Data] = compactMap {
            switch $0 {
            case let .response(_, .terminal(_, data)): data
            case let .push(.terminalOutput(_, _, data)): data
            default: nil
            }
        }
        return String(decoding: chunks.reduce(Data(), +), as: UTF8.self)
    }

    var openedRequests: [PendingRequest] { pushes.compactMap { if case let .requestOpened(r) = $0 { r } else { nil } } }

    func closed(_ request: UUID) -> RequestResolution? {
        pushes.lazy.compactMap { if case let .requestClosed(id, _, how, _) = $0, id == request { how } else { nil } }.first
    }
}

/// Short labels so event sequences compare readably.
private func label(_ e: ChatEvent) -> String {
    switch e {
    case .userMessage: "userMessage"
    case .assistantText: "assistantText"
    case .assistantTextReplaced: "assistantTextReplaced"
    case .toolStarted: "toolStarted"
    case .toolFinished: "toolFinished"
    case .requestOpened: "requestOpened"
    case .requestClosed: "requestClosed"
    case .turnEnded: "turnEnded"
    case .turnFailed: "turnFailed"
    case .turnInterrupted: "turnInterrupted"
    case .subagent: "subagent"
    case .system(let note): "system(\(note))"
    }
}

final class EngineTests: XCTestCase {
    private var root: URL!
    private var engines: [Engine] = []
    private var clients: [TestClient] = []
    private let timeout: TimeInterval = 10

    private var paths: SerifPaths { SerifPaths(root: root) }
    private var fakeLog: String { root.path + "/fake.log" }
    private var transcript: String { root.path + "/transcript.jsonl" }
    private var codexRPC: String { root.path + "/codex-rpc.jsonl" }
    private var binDir: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent() }

    // Unix socket paths must stay under 104 bytes: a short root in /tmp.
    override func setUp() { root = URL(fileURLWithPath: "/tmp/serif-e-\(UUID().uuidString.prefix(8))") }

    override func tearDown() {
        clients.forEach { $0.close() }
        for engine in engines { shutdown(engine) }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEngine(_ scenario: String, codex: String = "codex-basic", env extra: [String: String] = [:],
                            locate: (@Sendable (Agent) -> String?)? = nil) throws -> Engine {
        let scenarios = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/scenarios")
        let hook = binDir.appendingPathComponent("serif-hook").path
        let (fake, fakeCodex) = (binDir.appendingPathComponent("fake-claude").path, binDir.appendingPathComponent("fake-codex").path)
        let env = ["PATH": "/usr/bin:/bin", "SERIF_FAKE_SCENARIO": scenarios.appendingPathComponent("\(scenario).jsonl").path,
                   "SERIF_HOOK_BIN": hook, "SERIF_FAKE_LOG": fakeLog, "SERIF_FAKE_TRANSCRIPT": transcript, "CLAUDECODE": "1",
                   "CLAUDE_CONFIG_DIR": root.path + "/claude",      // the engine's catalog: never the real ~/.claude
                   "SERIF_FAKE_CODEX_SCENARIO": scenarios.appendingPathComponent("\(codex).jsonl").path, "SERIF_FAKE_CODEX_RPC": codexRPC]
            .merging(extra) { $1 }
        let engine = try Engine(paths: paths, locate: locate ?? { $0 == .claude ? fake : fakeCodex }, hookCommand: hook, environment: env)
        engines.append(engine)
        return engine
    }

    private func shutdown(_ engine: Engine) {
        let e = expectation(description: "shutdown")
        engine.shutdown { e.fulfill() }
        wait(for: [e], timeout: timeout)
    }

    private func connect() throws -> TestClient {
        let client = try XCTUnwrap(TestClient(path: paths.engineSocket.path))
        clients.append(client)
        return client
    }

    @discardableResult
    private func request(_ client: TestClient, _ r: AppRequest) -> ResponseBody? {
        let (e, id) = client.send(r)
        wait(for: [e], timeout: timeout)
        return client.response(id)
    }

    private func waitFor(_ client: TestClient, _ description: String, _ condition: @escaping ([EngineMessage]) -> Bool) {
        wait(for: [client.expectation(description, condition)], timeout: timeout)
    }

    func testPluginsAndConnectorsReachTheLaunch() throws {
        let engine = try makeEngine("basic")         // the data folder (root) exists from here on
        let plugin = root.appendingPathComponent("plug")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        let installed = root.appendingPathComponent("claude/plugins/installed_plugins.json")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version":2,"plugins":{"tool@shop":[{"scope":"user","installPath":"\#(plugin.path)"}]}}"#
            .write(to: installed, atomically: true, encoding: .utf8)
        try engine.start()
        let client = try connect()
        var bot = try createBot(client)
        _ = try launches(1)                          // let the first launch log before the project change kills it
        guard case let .snapshot(snapshot) = request(client, .snapshot), var project = snapshot.projects.first
        else { return XCTFail("no project") }
        project.plugins = ["tool@shop"]
        guard case .project = request(client, .updateProject(project)) else { return XCTFail("project update refused") }
        _ = try launches(2)                          // the project's plugins relaunch its bots
        bot.plugins = ["tool@shop", "gone@shop"]
        bot.connectors = true
        guard case .bot = request(client, .updateBot(bot)) else { return XCTFail("bot update refused") }
        let launched = try launches(3)
        func pluginDirs(_ args: [String]) -> [String] { args.indices.filter { args[$0] == "--plugin-dir" }.map { args[$0 + 1] } }
        XCTAssertEqual(launched[0].env["ENABLE_CLAUDEAI_MCP_SERVERS"], "false")
        XCTAssertEqual(pluginDirs(launched[0].args), [])
        XCTAssertEqual(pluginDirs(launched[1].args), [plugin.path])
        XCTAssertEqual(pluginDirs(launched[2].args), [plugin.path])     // once, though the bot names it too; "gone" left out
        XCTAssertNil(launched[2].env["ENABLE_CLAUDEAI_MCP_SERVERS"])
    }

    func testSkillLinksFollowTheBotAndItsProject() throws {
        let engine = try makeEngine("basic")
        let skill = root.appendingPathComponent("my-skills/tidy")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: tidy\n---\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try engine.start()
        let client = try connect()
        var bot = try createBot(client)
        _ = try launches(1)                          // let the first launch log before the update kills it
        bot.skills = [skill.path]
        guard case .bot = request(client, .updateBot(bot)) else { return XCTFail("update refused") }
        _ = try launches(2)                          // a new skill relaunches the bot
        let botLink = paths.bot(bot.id).workspace.appendingPathComponent(".claude/skills/tidy").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: botLink), skill.path)

        bot.skills = []
        guard case .bot = request(client, .updateBot(bot)) else { return XCTFail("update refused") }
        _ = try launches(3)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: botLink))
        guard case let .snapshot(snapshot) = request(client, .snapshot), var project = snapshot.projects.first
        else { return XCTFail("no project") }
        project.skills = [skill.path]
        guard case .project = request(client, .updateProject(project)) else { return XCTFail("project update refused") }
        _ = try launches(4)                          // the project's skills relaunch its bots
        let projectLink = paths.shared(project.id).appendingPathComponent(".claude/skills/tidy").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: projectLink), skill.path)
    }

    /// Waits until the fake has logged `count` launches; returns each launch's arguments and environment.
    private func launches(_ count: Int) throws -> [(args: [String], env: [String: String])] {
        let read = { [fakeLog] in (try? String(contentsOfFile: fakeLog, encoding: .utf8))?.split(separator: "\n") ?? [] }
        let logged = expectation(description: "\(count) launches")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            if read().count >= count { t.invalidate(); logged.fulfill() }
        }
        wait(for: [logged], timeout: timeout)
        poll.invalidate()
        return try read().map { line in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return (object["args"] as? [String] ?? [], object["env"] as? [String: String] ?? [:])
        }
    }

    /// A bot in `projectId`, or in a new project "P"; returns the bot as the engine created it.
    private func createBot(_ client: TestClient, in projectId: UUID? = nil, agent: Agent = .claude, connectors: Bool = false,
                           skills: [String] = [], plugins: [String] = [], freedom: Freedom = .ask) throws -> Bot {
        let project: UUID
        if let projectId { project = projectId } else {
            guard case let .project(p) = request(client, .createProject(name: "P", linkedFolder: nil, readLinkedInstructions: true))
            else { throw XCTSkip("createProject failed") }
            project = p.id
        }
        let new = NewBot(projectId: project, name: "Bob", face: randomFace(existing: []), agent: agent, model: nil,
                         instructions: "Help.", freedom: freedom, skills: skills, plugins: plugins, connectors: connectors)
        guard case let .bot(bot) = request(client, .createBot(new)) else { throw XCTSkip("createBot failed") }
        return bot
    }

    func testNewBotIntroducesItselfAndOnlyAProjectsFirstBotGivesTheTour() throws {
        try makeEngine("introduction").start()
        let client = try connect()
        let first = try createBot(client)
        waitFor(client, "first reply") { $0.chatEvents(first.id).contains { label($0) == "turnEnded" } }
        let intro = try XCTUnwrap(introduction(client.all.chatEvents(first.id)))
        XCTAssertTrue(intro.contains("three sentences"))                // the helper's bot has instructions
        XCTAssertTrue(intro.contains("first bot in this project"))
        // An archived bot still counts: the project's next bot gets no tour.
        XCTAssertEqual(request(client, .archiveBot(id: first.id)), .ok)
        let second = try createBot(client, in: first.projectId)
        waitFor(client, "second reply") { $0.chatEvents(second.id).contains { label($0) == "turnEnded" } }
        XCTAssertFalse(try XCTUnwrap(introduction(client.all.chatEvents(second.id))).contains("first bot in this project"))
        // The introduction is the conversation's first message: the next launch resumes it.
        XCTAssertEqual(request(client, .restartBot(id: second.id)), .ok)
        XCTAssertEqual(try launches(3)[2].args.suffix(2), ["--resume", second.sessionId.uuidString])
    }

    private func introduction(_ events: [ChatEvent]) -> String? {
        events.lazy.compactMap { if case let .userMessage(text, _, .introduction) = $0 { text } else { nil } }.first
    }

    func testSignedOutClaudeCodeStopsTheBotUntilRetry() throws {
        let flag = root.path + "/logged-out"
        let engine = try makeEngine("basic", env: ["SERIF_FAKE_LOGGED_OUT": flag])
        FileManager.default.createFile(atPath: flag, contents: nil)      // the data folder exists once the engine does
        try engine.start()
        let client = try connect()
        let bot = try createBot(client)
        let stopped = BotState.crashed(reason: AgentProblem.claudeNotSignedIn.rawValue, retryAt: nil)
        waitFor(client, "stopped: not signed in") { $0.summaries(bot.id).contains { $0.state == stopped } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeLog), "a signed-out Claude Code was launched")
        guard case let .agentStatus(status) = request(client, .agentStatus(.claude)) else { return XCTFail("no status") }
        XCTAssertEqual(status.loggedIn, false)
        XCTAssertEqual(status.version, "2.1.296")

        try FileManager.default.removeItem(atPath: flag)                // the user signs in
        XCTAssertEqual(request(client, .restartBot(id: bot.id)), .ok)
        waitFor(client, "ready after Retry") { $0.summaries(bot.id).contains { $0.state == .ready } }
    }

    func testBotsStoppedForClaudeCodeStartOnceACheckFindsItFine() throws {
        let flag = root.path + "/logged-out"
        let engine = try makeEngine("basic", env: ["SERIF_FAKE_LOGGED_OUT": flag])
        FileManager.default.createFile(atPath: flag, contents: nil)
        try engine.start()
        let client = try connect()
        let first = try createBot(client)
        let second = try createBot(client, in: first.projectId)
        let stopped = BotState.crashed(reason: AgentProblem.claudeNotSignedIn.rawValue, retryAt: nil)
        waitFor(client, "both stopped: not signed in") { m in [first, second].allSatisfy { m.summaries($0.id).contains { $0.state == stopped } } }

        try FileManager.default.removeItem(atPath: flag)                // the user signs in, then Retry asks for a check
        guard case .agentStatus = request(client, .agentStatus(.claude)) else { return XCTFail("no status") }
        XCTAssertEqual(try launches(2).count, 2)
        waitFor(client, "both ready") { m in [first, second].allSatisfy { m.summaries($0.id).contains { $0.state == .ready } } }
    }

    func testCrashChecksClaudeCodeAgain() throws {
        let flag = root.path + "/logged-out"
        try makeEngine("crash", env: ["SERIF_FAKE_LOGGED_OUT": flag]).start()
        let client = try connect()
        let bot = try createBot(client)
        _ = try launches(1)                                              // signed in: the first launch goes ahead
        FileManager.default.createFile(atPath: flag, contents: nil)      // signed out before the 2 s crash relaunch
        let stopped = BotState.crashed(reason: AgentProblem.claudeNotSignedIn.rawValue, retryAt: nil)
        waitFor(client, "stopped: not signed in") { $0.summaries(bot.id).contains { $0.state == stopped } }
        XCTAssertEqual(try launches(1).count, 1, "relaunched while signed out")

        try FileManager.default.removeItem(atPath: flag)
        XCTAssertEqual(request(client, .restartBot(id: bot.id)), .ok)
        XCTAssertEqual(try launches(2).count, 2)
    }

    func testCodexNotInstalledStopsItsBot() throws {
        let fake = binDir.appendingPathComponent("fake-claude").path
        try makeEngine("basic", locate: { $0 == .claude ? fake : nil }).start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        let stopped = BotState.crashed(reason: AgentProblem.codexNotInstalled.rawValue, retryAt: nil)
        waitFor(client, "stopped: not installed") { $0.summaries(bot.id).contains { $0.state == stopped } }
        guard case let .agentStatus(status) = request(client, .agentStatus(.codex)) else { return XCTFail("no status") }
        XCTAssertEqual(status, AgentStatus(agent: .codex, path: nil, version: nil, loggedIn: nil, email: nil))
    }

    func testClaudeCodeInstalledLaterIsFoundOnRetry() throws {
        let installed = root.path + "/installed"
        let fake = binDir.appendingPathComponent("fake-claude").path
        try makeEngine("basic", locate: { _ in FileManager.default.fileExists(atPath: installed) ? fake : nil }).start()
        let client = try connect()
        let bot = try createBot(client)
        let stopped = BotState.crashed(reason: AgentProblem.claudeNotInstalled.rawValue, retryAt: nil)
        waitFor(client, "stopped: not installed") { $0.summaries(bot.id).contains { $0.state == stopped } }
        guard case let .agentStatus(missing) = request(client, .agentStatus(.claude)) else { return XCTFail("no status") }
        XCTAssertFalse(missing.installed)

        FileManager.default.createFile(atPath: installed, contents: nil) // the user installs Claude Code, then presses Retry
        guard case let .agentStatus(found) = request(client, .agentStatus(.claude)) else { return XCTFail("no status") }
        XCTAssertEqual(found, AgentStatus(agent: .claude, path: fake, version: "2.1.296", loggedIn: true, email: "bot@example.com"))
        waitFor(client, "ready after Retry") { $0.summaries(bot.id).contains { $0.state == .ready } }    // no restart needed
    }

    func testClaudeCodeThatMovedIsLookedForAgain() throws {
        let fake = binDir.appendingPathComponent("fake-claude").path
        let old = root.path + "/old-claude"
        let engine = try makeEngine("basic", locate: { _ in FileManager.default.fileExists(atPath: old) ? old : fake })
        try FileManager.default.copyItem(atPath: fake, toPath: old)
        try engine.start()
        let client = try connect()
        guard case let .agentStatus(before) = request(client, .agentStatus(.claude)) else { return XCTFail("no status") }
        XCTAssertEqual(before.path, old)
        try FileManager.default.removeItem(atPath: old)                  // e.g. an update moved it
        guard case let .agentStatus(after) = request(client, .agentStatus(.claude)) else { return XCTFail("no status") }
        XCTAssertEqual(after.path, fake)
    }

    func testChatEventsStateAndUnread() throws {
        try makeEngine("basic").start()
        let client = try connect()
        let bot = try createBot(client)
        waitFor(client, "ready and unread") { $0.summaries(bot.id).contains { $0.state == .ready && $0.unread } }
        let messages = client.all
        XCTAssertEqual(messages.chatEvents(bot.id).map(label),
                       ["system(botCreated)", "userMessage", "assistantText", "turnEnded"])
        let last = try XCTUnwrap(messages.summaries(bot.id).last)
        XCTAssertEqual(last.state, .ready)
        XCTAssertTrue(last.unread)
        XCTAssertEqual(last.preview, "Ciao!")

        let seq = try XCTUnwrap(messages.pushes.compactMap { if case let .chatEvent(_, r) = $0 { r.seq } else { nil } }.max())
        XCTAssertEqual(request(client, .markRead(botId: bot.id, seq: seq)), .ok)
        guard case let .snapshot(snapshot) = request(client, .snapshot) else { return XCTFail("no snapshot") }
        XCTAssertEqual(snapshot.bots.first { $0.bot.id == bot.id }?.unread, false)
        XCTAssertEqual(client.all.summaries(bot.id).last?.unread, false)
    }

    func testTrustDialogAnsweredEvenWhenItRemounts() throws {
        try makeEngine("trust-remount").start()
        let client = try connect()
        let bot = try createBot(client)
        waitFor(client, "ready after the trust dialog") { $0.summaries(bot.id).contains { $0.state == .ready } }
    }

    func testOldInterruptedLineOnResumeIsNotATurn() throws {
        try makeEngine("interrupted-on-resume").start()
        let client = try connect()
        let bot = try createBot(client)
        request(client, .attachTerminal(botId: bot.id))
        waitFor(client, "screen after the old line") { $0.terminalText.contains("READY") }
        let events = client.all.chatEvents(bot.id).map(label)
        XCTAssertEqual(events, ["system(botCreated)", "system(resumed)"])
    }

    func testPermissionAnsweredInApp() throws {
        try makeEngine("permission").start()
        let client = try connect()
        let bot = try createBot(client)
        request(client, .attachTerminal(botId: bot.id))
        waitFor(client, "request opened") { !$0.openedRequests.isEmpty }
        let pending = try XCTUnwrap(client.all.openedRequests.first)
        XCTAssertEqual(pending.kind, .permission)
        XCTAssertEqual(pending.toolName, "Bash")
        XCTAssertEqual(pending.toolUseId, "toolu_1")

        XCTAssertEqual(request(client, .answer(requestId: pending.id, answer: .allow)), .ok)
        waitFor(client, "hook output in the PTY") { $0.terminalText.contains(#"HOOK-OUT:{"hookSpecificOutput""#) }
        waitFor(client, "request closed") { $0.closed(pending.id) != nil }
        XCTAssertEqual(client.all.closed(pending.id), .answeredInApp)
    }

    func testSendDuringOpenRequestWaitsForItToClose() throws {
        try makeEngine("permission-send").start()
        let client = try connect()
        let bot = try createBot(client)
        request(client, .attachTerminal(botId: bot.id))
        waitFor(client, "request opened") { !$0.openedRequests.isEmpty }
        let pending = try XCTUnwrap(client.all.openedRequests.first)

        // Enter in the dialog would answer it: the text must not reach the PTY while the request is open.
        XCTAssertEqual(request(client, .send(botId: bot.id, text: "wait")), .ok)
        request(client, .terminalInput(botId: bot.id, data: Data("GO".utf8)))
        waitFor(client, "fake read GO") { $0.terminalText.contains("GOT-GO") }
        XCTAssertFalse(client.all.terminalText.contains("EARLY-INPUT"), "the chat text reached the open dialog")
        XCTAssertNil(client.all.closed(pending.id))

        // Answered: the held text goes once the dialog has left.
        XCTAssertEqual(request(client, .answer(requestId: pending.id, answer: .allow)), .ok)
        waitFor(client, "paste delivered") { $0.terminalText.contains("GOT-PASTE") }
        waitFor(client, "chat message") {
            $0.chatEvents(bot.id).contains { $0 == .userMessage(text: "wait", promptId: "p1", origin: .chat) }
        }
    }

    func testPermissionResolvedInTerminal() throws {
        try makeEngine("permission-terminal").start()
        let client = try connect()
        let bot = try createBot(client)
        request(client, .attachTerminal(botId: bot.id))
        waitFor(client, "request opened") { !$0.openedRequests.isEmpty }
        let pending = try XCTUnwrap(client.all.openedRequests.first)

        // Let the fake go on to PostToolUse, as if the user had answered in the terminal.
        request(client, .terminalInput(botId: bot.id, data: Data("GO".utf8)))
        waitFor(client, "request closed") { $0.closed(pending.id) != nil }
        XCTAssertEqual(client.all.closed(pending.id), .answeredInTerminal)
        waitFor(client, "fake went on") { $0.terminalText.contains("AFTER-POST") }
        XCTAssertFalse(client.all.terminalText.contains("HOOK-OUT"))
    }

    func testSendWhileStartingWaitsForSessionStart() throws {
        try makeEngine("starting").start()
        let client = try connect()
        let bot = try createBot(client)
        XCTAssertEqual(client.all.summaries(bot.id).last?.state, .starting)
        XCTAssertEqual(request(client, .send(botId: bot.id, text: "hello")), .ok)
        request(client, .attachTerminal(botId: bot.id))
        waitFor(client, "paste received") { $0.terminalText.contains("GOT-PASTE") }
        XCTAssertFalse(client.all.terminalText.contains("EARLY-INPUT"), "the text reached the PTY before SessionStart")
        waitFor(client, "chat message") {
            $0.chatEvents(bot.id).contains { $0 == .userMessage(text: "hello", promptId: "p1", origin: .chat) }
        }
    }

    func testRestartResumesSessionAndKeepsHistory() throws {
        let first = try makeEngine("basic")
        try first.start()
        let client = try connect()
        let bot = try createBot(client)
        waitFor(client, "turn ended") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        client.close()
        shutdown(first)

        try makeEngine("basic").start()
        let launched = try launches(2)
        XCTAssertTrue(launched[0].args.contains("--session-id"))
        XCTAssertEqual(launched[1].args.suffix(2), ["--resume", bot.sessionId.uuidString])
        // The engine-built environment drops CLAUDE* variables.
        XCTAssertNil(launched[1].env["CLAUDECODE"])

        let second = try connect()
        guard case let .history(records) = request(second, .history(botId: bot.id, beforeSeq: nil, limit: 100))
        else { return XCTFail("no history") }
        XCTAssertEqual(Array(records.map(\.event).map(label).prefix(4)),
                       ["system(botCreated)", "userMessage", "assistantText", "turnEnded"])
    }

    func testCrashRelaunchesWithNoteAndSessionFromSessionStart() throws {
        try makeEngine("crash-after-start").start()
        let client = try connect()
        let bot = try createBot(client)
        let launched = try launches(2)
        // SessionStart alone is no conversation: the relaunch starts fresh, with the id SessionStart reported.
        XCTAssertEqual(launched[1].args.suffix(2), ["--session-id", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"])
        waitFor(client, "crash note") { $0.chatEvents(bot.id).contains(.system(.crashed(reason: "Exit code 3"))) }
        XCTAssertFalse(client.all.chatEvents(bot.id).contains(.system(.newConversation)))
        XCTAssertTrue(client.all.summaries(bot.id).contains { if case .crashed(_, let retryAt) = $0.state { retryAt != nil } else { false } })
    }

    func testCrashMidTurnClosesTheTurnAsInterrupted() throws {
        try makeEngine("crash-mid-turn").start()
        let client = try connect()
        let bot = try createBot(client)
        waitFor(client, "crash note") { $0.chatEvents(bot.id).contains(.system(.crashed(reason: "Exit code 3"))) }
        guard case let .history(records) = request(client, .history(botId: bot.id, beforeSeq: nil, limit: 100))
        else { return XCTFail("no history") }
        let events = records.map(\.event)
        XCTAssertEqual(Array(events.map(label).prefix(6)),
                       ["system(botCreated)", "userMessage", "toolStarted", "toolFinished", "turnInterrupted",
                        "system(crashed(reason: \"Exit code 3\"))"])
        XCTAssertTrue(events.contains(.toolFinished(toolUseId: "toolu_1", ok: false, output: "Interrupted", durationMs: nil)))
    }

    func testDeliberateRestartAddsNoCrashNote() throws {
        try makeEngine("basic").start()
        let client = try connect()
        let bot = try createBot(client)
        waitFor(client, "turn ended") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        XCTAssertEqual(request(client, .restartBot(id: bot.id)), .ok)
        waitFor(client, "second turn") { $0.chatEvents(bot.id).filter { label($0) == "turnEnded" }.count == 2 }
        XCTAssertEqual(try launches(2)[1].args.suffix(2), ["--resume", bot.sessionId.uuidString])
        XCTAssertFalse(client.all.chatEvents(bot.id).contains { if case .system(.crashed) = $0 { true } else { false } })
    }

    func testRenameDoesNotRelaunchButModelDoes() throws {
        try makeEngine("basic").start()
        let client = try connect()
        var bot = try createBot(client)
        waitFor(client, "turn ended") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        bot.name = "Robert"
        guard case .bot = request(client, .updateBot(bot)) else { return XCTFail("rename refused") }
        Thread.sleep(forTimeInterval: 1.5)          // a relaunch would have logged a second launch by now
        XCTAssertEqual(try launches(1).count, 1, "renaming relaunched the bot")
        bot.model = "haiku"
        guard case .bot = request(client, .updateBot(bot)) else { return XCTFail("model change refused") }
        XCTAssertEqual(try launches(2).count, 2)
    }

    func testProjectRenameWaitsForTheNextLaunch() throws {
        try makeEngine("basic").start()
        let client = try connect()
        let bot = try createBot(client)
        waitFor(client, "turn ended") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        guard case let .snapshot(snapshot) = request(client, .snapshot), var project = snapshot.projects.first
        else { return XCTFail("no project") }
        project.name = "Renamed"
        guard case .project = request(client, .updateProject(project)) else { return XCTFail("rename refused") }
        Thread.sleep(forTimeInterval: 1.5)          // a relaunch would have logged a second launch by now
        XCTAssertEqual(try launches(1).count, 1, "renaming the project relaunched its bot")
    }

    func testAgentAndThreadStayTheEngines() throws {
        try makeEngine("basic").start()
        let client = try connect()
        var bot = try createBot(client)
        _ = try launches(1)
        bot.agent = .codex                       // the agent never changes (spec §2)
        bot.threadId = "made-up"                 // Codex's thread is the engine's to keep
        bot.name = "Robert"
        guard case let .bot(saved) = request(client, .updateBot(bot)) else { return XCTFail("update refused") }
        XCTAssertEqual(saved.agent, .claude)
        XCTAssertNil(saved.threadId)
        XCTAssertEqual(saved.name, "Robert")
    }

    func testEachAgentRestartsForItsOwnPlugins() throws {
        try makeEngine("basic").start()
        let client = try connect()
        _ = try createBot(client)
        _ = try launches(1)
        guard case let .snapshot(snapshot) = request(client, .snapshot), var project = snapshot.projects.first
        else { return XCTFail("no project") }
        project.codexPlugins = ["browser@openai-bundled"]
        guard case let .project(saved) = request(client, .updateProject(project)) else { return XCTFail("project update refused") }
        XCTAssertEqual(saved.codexPlugins, ["browser@openai-bundled"])
        Thread.sleep(forTimeInterval: 1.5)       // a relaunch would have logged a second launch by now
        XCTAssertEqual(try launches(1).count, 1, "Codex plugins restarted a Claude Code bot")
    }

    func testPlanApprovalNeedsTheScreenAndKilledHookCancels() throws {
        try makeEngine("plan").start()
        let client = try connect()
        let bot = try createBot(client)
        waitFor(client, "request opened") { !$0.openedRequests.isEmpty }
        let pending = try XCTUnwrap(client.all.openedRequests.first)
        XCTAssertEqual(pending.kind, .plan)
        // The plan question is not on the fake's screen: the app is told to answer in the terminal, the request stays.
        guard case .error = request(client, .answer(requestId: pending.id, answer: .approvePlan)) else {
            return XCTFail("plan approved without the question on screen")
        }
        XCTAssertNil(client.all.closed(pending.id))
        request(client, .terminalInput(botId: bot.id, data: Data("GO".utf8)))     // the fake now kills its hook
        waitFor(client, "request closed") { $0.closed(pending.id) != nil }
        XCTAssertEqual(client.all.closed(pending.id), .cancelled)
    }

    func testTranscriptRestoresSkippedLines() throws {
        try makeEngine("repair").start()
        // Claude Code's own transcript has the line MessageDisplay skipped.
        try #"""
        {"type":"user","message":{"content":"count"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"1\n2\n3"}]}}
        """#.write(toFile: transcript, atomically: true, encoding: .utf8)
        let client = try connect()
        let bot = try createBot(client)
        waitFor(client, "repaired text") {
            $0.chatEvents(bot.id).contains(.assistantTextReplaced(messageId: "m1", text: "1\n2\n3"))
        }
        XCTAssertEqual(client.all.chatEvents(bot.id).map(label).suffix(2), ["turnEnded", "assistantTextReplaced"])
    }

    func testSecondEngineOnSameHomeIsRefused() throws {
        try makeEngine("basic").start()
        let other = try makeEngine("basic")
        XCTAssertThrowsError(try other.start()) { XCTAssertEqual($0 as? EngineError, .alreadyRunning) }
        // The running engine still answers.
        let client = try connect()
        guard case .welcome = request(client, .hello(protocolVersion: SerifProtocol.version)) else { return XCTFail("no welcome") }
    }

    // MARK: - Codex

    /// The messages fake-codex received, in order (the frames as JSON).
    private func codexMessages() -> [JSONValue] {
        ((try? String(contentsOfFile: codexRPC, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONValue.parse(Data($0.utf8)) }
    }

    /// The params of every `method` request fake-codex received.
    private func codexRequests(_ method: String) -> [JSONValue] {
        codexMessages().filter { $0["method"]?.string == method }.map { $0["params"] ?? .null }
    }

    func testCodexCatalogComesFromAServerOfItsOwn() throws {
        try makeEngine("basic").start()
        let client = try connect()
        guard case let .codexCatalog(catalog) = request(client, .codexCatalog) else { return XCTFail("no catalog") }
        XCTAssertEqual(catalog.plugins.map(\.id), ["browser@openai-bundled", "visualize@openai-bundled", "work-pets@openai-curated-remote"])
        XCTAssertEqual(catalog.remoteSkills, ["work-pets@openai-curated-remote": ["work-pets:pets"]])
        XCTAssertEqual(catalog.models.map(\.id), ["gpt-6-luna", "gpt-5.6-terra"])
        guard case .codexCatalog = request(client, .codexCatalog) else { return XCTFail("no catalog") }
        XCTAssertEqual(try launches(1).filter { $0.args.first == "app-server" }.count, 1, "kept, not read again")
    }

    func testRemoteSkillsAreWaitedFor() throws {
        try makeEngine("basic", codex: "codex-late-skills").start()
        let client = try connect()
        guard case let .codexCatalog(catalog) = request(client, .codexCatalog) else { return XCTFail("no catalog") }
        XCTAssertEqual(catalog.remoteSkills, ["work-pets@openai-curated-remote": ["work-pets:pets"]])
        XCTAssertEqual(codexRequests("skills/list").count, 2)
    }

    func testNoCodexNoCatalog() throws {
        let fake = binDir.appendingPathComponent("fake-claude").path
        try makeEngine("basic", locate: { $0 == .claude ? fake : nil }).start()
        let client = try connect()
        XCTAssertEqual(request(client, .codexCatalog), .error("Codex did not answer"))
    }

    func testRemotePluginWithoutSkillsStillGetsTheCatalog() throws {
        let engine = try makeEngine("basic", codex: "codex-no-remote-skills")
        engine.codexCatalogPollLimit = 2        // short, so the test is fast; the hard limit stays 20 s
        try engine.start()
        let client = try connect()
        guard case let .codexCatalog(catalog) = request(client, .codexCatalog) else { return XCTFail("no catalog") }
        XCTAssertTrue(catalog.plugins.map(\.id).contains("work-pets@openai-curated-remote"))
        XCTAssertNil(catalog.remoteSkills["work-pets@openai-curated-remote"])
    }

    func testFailedPluginListIsNoCatalogAndNotKept() throws {
        try makeEngine("basic", codex: "codex-plugins-fail").start()
        let client = try connect()
        XCTAssertEqual(request(client, .codexCatalog), .error("Codex did not answer"))
        XCTAssertEqual(request(client, .codexCatalog), .error("Codex did not answer"))     // read again (a new fake fails again)
        XCTAssertEqual(codexRequests("plugin/list").count, 2)
    }

    func testConcurrentCatalogRequestsShareOneServer() throws {
        try makeEngine("basic").start()
        let (a, b) = (try connect(), try connect())
        let ((ea, ida), (eb, idb)) = (a.send(.codexCatalog), b.send(.codexCatalog))
        wait(for: [ea, eb], timeout: timeout)
        guard case .codexCatalog = a.response(ida), case .codexCatalog = b.response(idb) else { return XCTFail("no catalog") }
        XCTAssertEqual(try launches(1).filter { $0.args.first == "app-server" }.count, 1)
    }

    func testShutdownDuringACatalogReadStopsItsServer() throws {
        let engine = try makeEngine("basic", env: ["SERIF_FAKE_CODEX_DELAY": "5"])
        try engine.start()
        var answers: [CodexCatalog?] = []
        let answered = expectation(description: "answered")
        engine.queue.async { engine.codexCatalog { answers.append($0); answered.fulfill() } }
        _ = try launches(1)
        let server = try XCTUnwrap(engine.queue.sync { engine.codexCatalogServer })
        shutdown(engine)
        wait(for: [answered], timeout: timeout)
        XCTAssertNil(answers.first ?? nil)
        XCTAssertFalse(engine.queue.sync { server.isRunning }, "its process is gone")
        engine.queue.sync { engine.codexCatalog { answers.append($0) } }
        XCTAssertEqual(answers.count, 2, "refused at once while stopping")
        XCTAssertNil(engine.queue.sync { engine.codexCatalogServer })
    }

    /// The app-servers started for `bot` (the catalog's own server runs in the data folder), with their environment.
    private func codexServers(_ bot: Bot) throws -> [(args: [String], env: [String: String])] {
        let read = { [fakeLog] in (try? String(contentsOfFile: fakeLog, encoding: .utf8))?.split(separator: "\n") ?? [] }
        return try read().compactMap { line in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            guard (object["cwd"] as? String)?.hasSuffix(bot.id.uuidString + "/workspace") == true,
                  (object["args"] as? [String])?.first == "app-server" else { return nil }
            return (object["args"] as? [String] ?? [], object["env"] as? [String: String] ?? [:])
        }
    }

    func testCodexBotStartsOnAnIsolatedServerOfItsOwn() throws {
        try makeEngine("basic").start()
        let skill = root.appendingPathComponent("my-skills/tidy")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: tidy\n---\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let client = try connect()
        let bot = try createBot(client, agent: .codex, skills: [skill.path])
        waitFor(client, "ready") { $0.summaries(bot.id).contains { $0.state == .ready } }
        let server = try XCTUnwrap(codexServers(bot).first)
        // Every installed plugin off but the chosen (none here), the remote one's skills hidden, the account's connectors off.
        XCTAssertEqual(Array(server.args.suffix(12)), ["--disable", "hooks", "-c", "notify=[]",
                                                        "-c", "plugins.browser@openai-bundled.enabled=false",
                                                        "-c", "plugins.visualize@openai-bundled.enabled=false",
                                                        "-c", #"skills.config=[{name="work-pets:pets",enabled=false}]"#,
                                                        "--disable", "apps"])
        XCTAssertEqual(server.args.firstIndex(of: "--ws-token-sha256").map { server.args[$0 + 1].count }, 64)   // the hash, not the secret
        XCTAssertNil(server.env["CLAUDECODE"])
        let workspace = paths.bot(bot.id).workspace.path
        let start = try XCTUnwrap(codexRequests("thread/start").first)
        XCTAssertEqual(start["cwd"]?.string, workspace)
        XCTAssertEqual(start["sandbox"], "workspace-write")
        XCTAssertEqual(start["approvalPolicy"], "untrusted")
        XCTAssertEqual(start["model"], "gpt-6-luna")                        // "Default" is Codex's default model
        XCTAssertTrue(start["developerInstructions"]?.string?.contains("AGENTS.md") ?? false)
        XCTAssertEqual(start["config"], ["sandbox_workspace_write": ["writable_roots": [.string(workspace), .string(paths.shared(bot.projectId).path)]]])
        XCTAssertEqual(codexRequests("experimentalFeature/list").first?["threadId"], "thr-1")
        XCTAssertEqual(codexRequests("mcpServerStatus/list").first?["threadId"], "thr-1")
        let link = paths.bot(bot.id).workspace.appendingPathComponent(".agents/skills/tidy").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), skill.path)
    }

    func testEveryTurnPassesTheBotsFreedomAgain() throws {
        // SAFETY: Codex keeps a turn's approval and sandbox for the turns after it, so a turn typed in the terminal would leave
        // its own to the chat's next turns: every turn/start of Serif's passes the bot's again.
        try makeEngine("basic").start()
        let client = try connect()
        guard case let .project(p) = request(client, .createProject(name: "P", linkedFolder: nil, readLinkedInstructions: true))
        else { return XCTFail("no project") }
        let expected: [(Freedom, JSONValue)] = [(.ask, "untrusted"), (.edits, "on-request"), (.auto, "never")]
        for (freedom, approval) in expected {
            let bot = try createBot(client, in: p.id, agent: .codex, freedom: freedom)
            waitFor(client, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
            let start = try XCTUnwrap(codexRequests("turn/start").last)
            let roots: JSONValue = [.string(paths.bot(bot.id).workspace.path), .string(paths.shared(p.id).path)]
            XCTAssertEqual(start["approvalPolicy"], approval, "\(freedom)")
            XCTAssertEqual(start["sandboxPolicy"], ["type": "workspaceWrite", "writableRoots": roots], "\(freedom)")
        }
    }

    func testThreadSettingsChangedCheckTheIsolationAgain() throws {
        // SAFETY backstop: the terminal can change the thread's settings; the isolation is checked again then, and a bot that
        // no longer shows it stops.
        try makeEngine("basic", codex: "codex-settings-hooks-on").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        let stopped = BotState.crashed(reason: CodexText.isolation, retryAt: nil)
        waitFor(client, "stopped: isolation") { $0.summaries(bot.id).contains { $0.state == stopped } }
        XCTAssertEqual(codexRequests("experimentalFeature/list").count, 2)
        XCTAssertEqual(codexRequests("mcpServerStatus/list").count, 2)
        XCTAssertTrue(client.all.chatEvents(bot.id).contains(.system(.crashed(reason: CodexText.isolation))))
    }

    func testLinkedFolderIsWritableOnlyWhenItExists() throws {
        try makeEngine("basic").start()
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        let client = try connect()
        var bots: [Bot] = []
        for folder in [linked.path, root.path + "/gone"] {
            guard case let .project(p) = request(client, .createProject(name: "P", linkedFolder: folder, readLinkedInstructions: true))
            else { return XCTFail("no project") }
            bots.append(try createBot(client, in: p.id, agent: .codex))
        }
        waitFor(client, "both ready") { m in bots.allSatisfy { b in m.summaries(b.id).contains { $0.state == .ready } } }
        let roots = { [self] (bot: Bot) in
            codexRequests("thread/start").first { $0["cwd"]?.string == paths.bot(bot.id).workspace.path }?["config"]?["sandbox_workspace_write"]?["writable_roots"]
        }
        let (present, missing) = (bots[0], bots[1])
        XCTAssertEqual(roots(present), [.string(paths.bot(present.id).workspace.path), .string(paths.shared(present.projectId).path), .string(linked.path)])
        XCTAssertEqual(roots(missing), [.string(paths.bot(missing.id).workspace.path), .string(paths.shared(missing.projectId).path)])
    }

    func testHooksReportedOnStopTheBot() throws {
        // Review Focus 1: whatever turned them back on (a thread config, a new Codex), the bot never runs with them.
        try makeEngine("basic", codex: "codex-hooks-on").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        let stopped = BotState.crashed(reason: CodexText.isolation, retryAt: nil)
        waitFor(client, "stopped: isolation") { $0.summaries(bot.id).contains { $0.state == stopped } }
        XCTAssertTrue(client.all.chatEvents(bot.id).contains(.system(.crashed(reason: CodexText.isolation))))
        Thread.sleep(forTimeInterval: 2.5)       // a crash would relaunch it after 2 s
        XCTAssertEqual(try codexServers(bot).count, 1)
        XCTAssertTrue(codexRequests("turn/start").isEmpty, "the introduction reached a bot that is not isolated")
    }

    func testAccountConnectorsLeftOnStopTheBot() throws {
        try makeEngine("basic", codex: "codex-apps-on").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        let stopped = BotState.crashed(reason: CodexText.isolation, retryAt: nil)
        waitFor(client, "stopped: isolation") { $0.summaries(bot.id).contains { $0.state == stopped } }
    }

    func testConnectorsListedOnMorePagesStopTheBot() throws {
        // A first page without codex_apps does not show it gone: it may be on the next one.
        try makeEngine("basic", codex: "codex-apps-paged").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        let stopped = BotState.crashed(reason: CodexText.isolation, retryAt: nil)
        waitFor(client, "stopped: isolation") { $0.summaries(bot.id).contains { $0.state == stopped } }
    }

    func testConnectorsOnAreLeftOn() throws {
        try makeEngine("basic").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex, connectors: true)
        waitFor(client, "ready") { $0.summaries(bot.id).contains { $0.state == .ready } }
        XCTAssertFalse(try XCTUnwrap(codexServers(bot).first).args.contains("apps"))
        XCTAssertTrue(codexRequests("mcpServerStatus/list").isEmpty)
    }

    func testCodexThatAnswersDifferentlyStopsTheBot() throws {
        // Review Focus 2: a Codex updated with the ChatGPT app that no longer knows a method: stopped with its message.
        try makeEngine("basic", codex: "codex-unknown").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        let stopped = BotState.crashed(reason: "Codex: unknown method thread/start", retryAt: nil)
        waitFor(client, "stopped") { $0.summaries(bot.id).contains { $0.state == stopped } }
    }

    func testCodexRefusingTheHandshakeStopsTheBotAndItsServer() throws {
        // Codex's own error at the start is Codex answering differently too: stopped, its server with it, never relaunched.
        let scenario = root.path + "/scenario.jsonl"
        let engine = try makeEngine("basic", env: ["SERIF_FAKE_CODEX_SCENARIO": scenario])
        FileManager.default.createFile(atPath: scenario, contents: nil)
        try engine.start()
        let client = try connect()
        guard case .codexCatalog = request(client, .codexCatalog) else { return XCTFail("no catalog") }     // read before the refusal
        try #"{"reply": "initialize", "error": "unsupported client"}"#.write(toFile: scenario, atomically: true, encoding: .utf8)
        let bot = try createBot(client, agent: .codex)
        let stopped = BotState.crashed(reason: "Codex: unsupported client", retryAt: nil)
        waitFor(client, "stopped") { $0.summaries(bot.id).contains { $0.state == stopped } }
        XCTAssertTrue(client.all.chatEvents(bot.id).contains(.system(.crashed(reason: "Codex: unsupported client"))))
        Thread.sleep(forTimeInterval: 2.5)       // a crash would relaunch it after 2 s
        XCTAssertEqual(try codexServers(bot).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bot(bot.id).dir.appendingPathComponent("codex.pid").path),
                       "its server is still running")
    }

    func testCodexSlowToStartIsWaitedForThenGivenUpOn() throws {
        // Review Focus 3: a server that answers late is waited for; one that never gets ready in time is a crash.
        let slow = try makeEngine("basic", env: ["SERIF_FAKE_CODEX_DELAY": "1"])
        try slow.start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "ready") { $0.summaries(bot.id).contains { $0.state == .ready } }
        client.close()
        shutdown(slow)

        let late = try makeEngine("basic", env: ["SERIF_FAKE_CODEX_DELAY": "3"])
        late.codexStartupTimeout = 1
        try late.start()
        let second = try connect()
        let pidFile = paths.bot(bot.id).dir.appendingPathComponent("codex.pid").path
        waitUntil("its server started") { FileManager.default.fileExists(atPath: pidFile) }
        let pid = try XCTUnwrap(pid_t(try String(contentsOfFile: pidFile, encoding: .utf8).split(separator: " ")[0]))
        waitFor(second, "crashed, to start again") {
            $0.summaries(bot.id).contains { if case .crashed(CodexText.notStarted, let retryAt) = $0.state { retryAt != nil } else { false } }
        }
        XCTAssertTrue(second.all.chatEvents(bot.id).contains(.system(.crashed(reason: CodexText.notStarted))))
        // The server given up on is stopped then, not left to answer later (this one would at 3 s).
        waitUntil("given-up server stopped", timeout: 1) { kill(pid, 0) != 0 }
    }

    func testPortTakenStartsCodexOnAnother() throws {
        // Review Focus 3: the port went to someone else between the check and Codex's start: another port, no crash.
        let busy = root.path + "/busy"
        let engine = try makeEngine("basic", env: ["SERIF_FAKE_CODEX_BUSY": busy])
        FileManager.default.createFile(atPath: busy, contents: nil)
        try engine.start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "ready") { $0.summaries(bot.id).contains { $0.state == .ready } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: busy))
        XCTAssertFalse(client.all.chatEvents(bot.id).contains { if case .system(.crashed) = $0 { true } else { false } })
    }

    func testCodexSignedOutStopsItsBotsUntilACheckFindsItFine() throws {
        let (flag, claudeFlag) = (root.path + "/codex-logged-out", root.path + "/logged-out")
        let engine = try makeEngine("basic", env: ["SERIF_FAKE_CODEX_LOGGED_OUT": flag, "SERIF_FAKE_LOGGED_OUT": claudeFlag])
        FileManager.default.createFile(atPath: flag, contents: nil)
        FileManager.default.createFile(atPath: claudeFlag, contents: nil)
        try engine.start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        let claudeBot = try createBot(client, in: bot.projectId)
        let stopped = BotState.crashed(reason: AgentProblem.codexNotSignedIn.rawValue, retryAt: nil)
        let claudeStopped = BotState.crashed(reason: AgentProblem.claudeNotSignedIn.rawValue, retryAt: nil)
        waitFor(client, "both stopped: not signed in") { m in
            m.summaries(bot.id).contains { $0.state == stopped } && m.summaries(claudeBot.id).contains { $0.state == claudeStopped }
        }
        XCTAssertTrue(try codexServers(bot).isEmpty)
        // The user signs in to both, then Retry asks for a check of Codex: only Codex's bots start, Claude Code's wait for theirs.
        try FileManager.default.removeItem(atPath: flag)
        try FileManager.default.removeItem(atPath: claudeFlag)
        guard case .agentStatus = request(client, .agentStatus(.codex)) else { return XCTFail("no status") }
        waitFor(client, "ready") { $0.summaries(bot.id).contains { $0.state == .ready } }
        XCTAssertEqual(engine.queue.sync { engine.bots[claudeBot.id]?.tracker.state }, claudeStopped)
    }

    func testCodexServerThatExitsIsRelaunched() throws {
        try makeEngine("basic", codex: "codex-exit").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "crashed, to start again") {
            $0.summaries(bot.id).contains { if case .crashed("Exit code 3", let retryAt) = $0.state { retryAt != nil } else { false } }
        }
        XCTAssertTrue(client.all.chatEvents(bot.id).contains(.system(.crashed(reason: "Exit code 3"))))
        waitUntil("relaunched") { [unowned self] in (try? codexServers(bot).count) ?? 0 >= 2 }
    }

    /// Waits until `condition` holds, asked every 0.05 s.
    private func waitUntil(_ description: String, timeout: TimeInterval? = nil, _ condition: @escaping () -> Bool) {
        let met = expectation(description: description)
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            if condition() { t.invalidate(); met.fulfill() }
        }
        wait(for: [met], timeout: timeout ?? self.timeout)
        poll.invalidate()
    }

    func testRestartDuringAFailingCatalogReadIsOneCrash() throws {
        // The read in progress is shared: the bot waits for it once, so it fails once, with one relaunch after it.
        let engine = try makeEngine("basic", codex: "codex-plugins-fail", env: ["SERIF_FAKE_CODEX_DELAY": "1"])
        try engine.start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        _ = try launches(1)                                  // the catalog's server, still starting
        XCTAssertEqual(request(client, .restartBot(id: bot.id)), .ok)
        let crashes = { client.all.chatEvents(bot.id).filter { if case .system(.crashed) = $0 { true } else { false } }.count }
        waitFor(client, "crashed") { $0.chatEvents(bot.id).contains(.system(.crashed(reason: "Codex did not answer"))) }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(crashes(), 1)
        XCTAssertEqual(engine.queue.sync { engine.store.meta(bot.id).crashCount }, 1)
        waitUntil("relaunched, failed again") { crashes() >= 2 }      // 2 s later, then the 1 s read
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(crashes(), 2)
        XCTAssertEqual(codexRequests("plugin/list").count, 2, "one read per round")
    }

    func testChosenPluginsAndProjectSkillsReachTheCodexBot() throws {
        try makeEngine("basic").start()
        let (tidy, docs) = (root.appendingPathComponent("my-skills/tidy"), root.appendingPathComponent("my-skills/docs"))
        for skill in [tidy, docs] {
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try "---\nname: x\n---\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let client = try connect()
        guard case .project(var project) = request(client, .createProject(name: "P", linkedFolder: nil, readLinkedInstructions: true))
        else { return XCTFail("no project") }
        project.codexPlugins = ["visualize@openai-bundled"]
        project.skills = [tidy.path, docs.path]
        guard case .project = request(client, .updateProject(project)) else { return XCTFail("project update refused") }
        let bot = try createBot(client, in: project.id, agent: .codex, skills: [tidy.path],
                                plugins: ["browser@openai-bundled", "work-pets@openai-curated-remote"])
        waitFor(client, "ready") { $0.summaries(bot.id).contains { $0.state == .ready } }
        // The bot's and the project's plugins on; the chosen remote plugin's skills not hidden.
        let args = try XCTUnwrap(codexServers(bot).first).args
        XCTAssertEqual(Array(args.suffix(8)), ["-c", "notify=[]", "-c", "plugins.browser@openai-bundled.enabled=true",
                                               "-c", "plugins.visualize@openai-bundled.enabled=true", "--disable", "apps"])
        let skills = paths.bot(bot.id).workspace.appendingPathComponent(".agents/skills")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: skills.appendingPathComponent("docs").path), docs.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: skills.appendingPathComponent("tidy").path), tidy.path)
        // Chosen by both: linked once, with no "left out" in the log.
        XCTAssertFalse(((try? String(contentsOf: paths.log, encoding: .utf8)) ?? "").contains("another chosen skill"))
    }

    func testShutdownWhileACodexBotWaitsForTheCatalogIsNoCrash() throws {
        let engine = try makeEngine("basic", env: ["SERIF_FAKE_CODEX_DELAY": "5"])
        try engine.start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        _ = try launches(1)                                  // the catalog's server, still starting
        shutdown(engine)
        let events = try engine.store.records(bot: bot.id, afterSeq: 0).map(\.event)
        XCTAssertFalse(events.contains { if case .system(.crashed) = $0 { true } else { false } })
    }

    func testCodexServersLeftByACrashedEngineAreStoppedAtStart() throws {
        let engine = try makeEngine("basic")
        // A bot's app-server an engine killed with SIGKILL left behind, and a catalog pid since reused by another
        // `codex app-server` (the ChatGPT app's, say): only the one with the recorded secret's hash is Serif's.
        let (orphan, other) = (Process(), Process())
        let hashes = [codexTokenHash(codexToken()), codexTokenHash(codexToken())]
        for (process, hash) in zip([orphan, other], hashes) {
            process.executableURL = binDir.appendingPathComponent("fake-codex")
            process.arguments = codexServerArgs(listen: "ws://127.0.0.1:\(try XCTUnwrap(freePort()))", tokenHash: hash)
            process.environment = [:]
        }
        let gone = expectation(description: "orphan stopped")
        orphan.terminationHandler = { _ in gone.fulfill() }
        try orphan.run()
        try other.run()
        defer { [orphan, other].forEach { if $0.isRunning { kill($0.processIdentifier, SIGKILL) } } }
        let files = [paths.bot(UUID()).dir.appendingPathComponent("codex.pid"), paths.root.appendingPathComponent("codex-catalog.pid")]
        for (file, process) in zip(files, [orphan, other]) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(process.processIdentifier) \(hashes[0])".write(to: file, atomically: true, encoding: .utf8)
        }
        try engine.start()
        wait(for: [gone], timeout: timeout)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(other.isRunning, "another program's Codex server is left alone")
        XCTAssertFalse(files.contains { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testCodexBotIntroducesItselfInItsFirstTurn() throws {
        try makeEngine("basic").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        XCTAssertEqual(client.all.chatEvents(bot.id).map(label), ["system(botCreated)", "userMessage", "assistantText", "turnEnded"])
        let intro = try XCTUnwrap(introduction(client.all.chatEvents(bot.id)))
        XCTAssertEqual(codexRequests("turn/start").first?["input"], [["type": "text", "text": .string(intro)]])
        // The thread is kept once it has a turn: from now on it resumes, and its terminal can open.
        XCTAssertEqual(client.all.summaries(bot.id).last?.bot.threadId, "thr-1")
    }

    func testCodexResumesItsThreadWithEverySettingAgain() throws {
        try makeEngine("basic").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        XCTAssertEqual(request(client, .restartBot(id: bot.id)), .ok)
        waitFor(client, "resumed") { $0.chatEvents(bot.id).contains(.system(.resumed)) }
        let resume = try XCTUnwrap(codexRequests("thread/resume").first)
        XCTAssertEqual(resume["threadId"], "thr-1")
        XCTAssertEqual(resume["sandbox"], "workspace-write")               // Codex forgets it on resume (spec §3.5)
        XCTAssertEqual(resume["approvalPolicy"], "untrusted")
        XCTAssertNotNil(resume["config"]?["sandbox_workspace_write"])
        XCTAssertEqual(codexRequests("thread/start").count, 1)
    }

    func testMessageSentWhileRestartingReachesTheNextLaunch() throws {
        // The old server is going (no connection) but still counted as ready: the text waits for the new one.
        try makeEngine("basic").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        let ((restarted, _), (sent, _)) = (client.send(.restartBot(id: bot.id)), client.send(.send(botId: bot.id, text: "Ancora?")))
        wait(for: [restarted, sent], timeout: timeout)
        waitFor(client, "delivered") { $0.chatEvents(bot.id).contains(.userMessage(text: "Ancora?", promptId: "turn-1", origin: .chat)) }
        // Never written to the old server: sent once, to the new one.
        XCTAssertEqual(codexRequests("turn/start").filter { $0["input"]?.array?.first?["text"] == "Ancora?" }.count, 1)
    }

    func testAThreadCodexLostStartsANewConversation() throws {
        let engine = try makeEngine("basic", codex: "codex-lost-thread")
        try engine.start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        XCTAssertEqual(request(client, .restartBot(id: bot.id)), .ok)          // the thread was archived in the ChatGPT app
        waitFor(client, "new conversation") { $0.chatEvents(bot.id).contains(.system(.newConversation)) }
        waitFor(client, "ready") { $0.summaries(bot.id).last?.state == .ready }
        XCTAssertEqual(codexRequests("thread/start").count, 2)
        // The lost thread is forgotten: the new one is kept at its first turn, as any new thread.
        XCTAssertNil(client.all.summaries(bot.id).last?.bot.threadId)
        XCTAssertNil(engine.queue.sync { engine.store.bots.first { $0.id == bot.id }?.threadId })
    }

    func testMessageDuringATurnSteersIt() throws {
        try makeEngine("basic", codex: "codex-steer").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "turn running") { $0.chatEvents(bot.id).contains { label($0) == "userMessage" } }
        XCTAssertEqual(request(client, .send(botId: bot.id, text: "Aggiungi BANANA")), .ok)
        waitFor(client, "turn ended") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        XCTAssertEqual(codexRequests("turn/steer"), [["threadId": "thr-1", "expectedTurnId": "turn-1", "input": [["type": "text", "text": "Aggiungi BANANA"]]]])
        XCTAssertEqual(codexRequests("turn/start").count, 1)
        XCTAssertTrue(client.all.chatEvents(bot.id).contains(.userMessage(text: "Aggiungi BANANA", promptId: "turn-1", origin: .chat)))
    }

    func testApprovalAnsweredInTheChatClosesOnce() throws {
        // Review Focus 4: Codex then tells every client the request is resolved; the card does not close twice.
        try makeEngine("basic", codex: "codex-approval").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "card") { !$0.openedRequests.isEmpty }
        let card = try XCTUnwrap(client.all.openedRequests.first)
        XCTAssertEqual(card.kind, .permission)
        XCTAssertEqual(card.toolName, "Bash")
        XCTAssertEqual(card.input["command"], "touch a.txt")
        XCTAssertEqual(card.toolUseId, "exec-1")
        XCTAssertEqual(card.decisions, ["accept", "acceptForSession", "decline", "cancel"])
        XCTAssertEqual(request(client, .answer(requestId: card.id, answer: .allowSession)), .ok)
        waitFor(client, "turn ended") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        XCTAssertTrue(codexMessages().contains(["id": 0, "result": ["decision": "acceptForSession"]]))
        let closes = client.all.pushes.filter { if case let .requestClosed(id, _, _, _) = $0 { id == card.id } else { false } }
        XCTAssertEqual(closes, [.requestClosed(requestId: card.id, botId: bot.id, resolution: .answeredInApp, answer: .allowSession)])
    }

    func testApprovalAnsweredInTheTerminalRefusesTheChat() throws {
        // Review Focus 4: the terminal answered first; the chat's late answer is refused and never reaches Codex.
        try makeEngine("basic", codex: "codex-terminal-answer").start()
        let client = try connect()
        _ = try createBot(client, agent: .codex)
        waitFor(client, "card closed") { m in m.openedRequests.first.map { m.closed($0.id) != nil } ?? false }
        let card = try XCTUnwrap(client.all.openedRequests.first)
        XCTAssertEqual(client.all.closed(card.id), .answeredInTerminal)
        XCTAssertEqual(request(client, .answer(requestId: card.id, answer: .allow)), .error("The request is already closed"))
        XCTAssertFalse(codexMessages().contains { $0["result"]?["decision"] != nil })
    }

    func testAnswerThatDoesNotFitIsRefusedAndTheCardStays() throws {
        // An answer Codex did not offer is never sent: refused, the card waits for one that fits.
        try makeEngine("basic", codex: "codex-approval").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "card") { !$0.openedRequests.isEmpty }
        let card = try XCTUnwrap(client.all.openedRequests.first)
        XCTAssertEqual(request(client, .answer(requestId: card.id, answer: .approvePlan)), .error("This answer does not fit the request"))
        XCTAssertNil(client.all.closed(card.id))
        XCTAssertEqual(request(client, .answer(requestId: card.id, answer: .deny(message: nil))), .ok)
        waitFor(client, "turn ended") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        XCTAssertEqual(codexMessages().filter { $0["id"] == 0 && $0["method"] == nil }, [["id": 0, "result": ["decision": "decline"]]])
    }

    func testInterruptStopsTheTurn() throws {
        try makeEngine("basic", codex: "codex-interrupt").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "turn running") { $0.chatEvents(bot.id).contains { label($0) == "userMessage" } }
        XCTAssertEqual(request(client, .interrupt(botId: bot.id)), .ok)
        waitFor(client, "interrupted") { $0.chatEvents(bot.id).contains(.turnInterrupted) }
        XCTAssertEqual(codexRequests("turn/interrupt"), [["threadId": "thr-1", "turnId": "turn-1"]])
        waitFor(client, "ready") { $0.summaries(bot.id).last?.state == .ready }
    }

    func testUsageLimitShowsOnTheBot() throws {
        try makeEngine("basic", codex: "codex-limit").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "limited") { $0.summaries(bot.id).contains { $0.state == .rateLimited(until: nil) } }
        XCTAssertTrue(client.all.chatEvents(bot.id).contains(.turnFailed(reason: "You've hit your usage limit.")))
    }

    func testRequestSerifCannotShowIsRefused() throws {
        // Review Focus 2: a request a newer Codex makes that Serif has no card for: refused, the turn does not hang.
        try makeEngine("basic", codex: "codex-unknown-request").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "turn running") { $0.chatEvents(bot.id).contains { label($0) == "userMessage" } }
        let refused = expectation(description: "refused")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [unowned self] t in
            if codexMessages().contains(where: { $0["id"] == 7 && $0["error"] != nil }) { t.invalidate(); refused.fulfill() }
        }
        wait(for: [refused], timeout: timeout)
        poll.invalidate()
        XCTAssertEqual(client.all.summaries(bot.id).last?.state, .working(.thinking))      // the bot goes on
    }

    func testCodexCrashMidTurnClosesTheTurnAndResumes() throws {
        try makeEngine("basic", codex: "codex-crash").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "resumed") { $0.chatEvents(bot.id).contains(.system(.resumed)) }
        XCTAssertEqual(client.all.chatEvents(bot.id).map(label),
                       ["system(botCreated)", "userMessage", "turnInterrupted", "system(crashed(reason: \"Exit code 3\"))", "system(resumed)"])
        XCTAssertEqual(codexRequests("thread/resume").first?["threadId"], "thr-1")
    }

    func testCodexCrashMidReplyKeepsWhatStreamed() throws {
        // The reply being written when the server died stays in the chat, its unfinished line too.
        try makeEngine("basic", codex: "codex-crash-mid-reply").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "interrupted") { $0.chatEvents(bot.id).contains(.turnInterrupted) }
        let events = client.all.chatEvents(bot.id)
        let text = events.compactMap { if case let .assistantText(_, _, delta, _, _) = $0 { delta } else { nil } }.joined()
        XCTAssertEqual(text, "Prima riga\nmezza ri")
        XCTAssertEqual(events.map(label).prefix(5), ["system(botCreated)", "userMessage", "assistantText", "assistantText", "turnInterrupted"])
    }

    /// The text of each `method` request fake-codex received, with the turn it named (a steer's).
    private func codexTexts(_ method: String) -> [String] {
        codexRequests(method).map { p in
            [p["input"]?.array?.first?["text"]?.string, p["expectedTurnId"]?.string].compactMap { $0 }.joined(separator: "@")
        }
    }

    func testRefusedSteerOpensANewTurn() throws {
        // The turn ended before Codex got the steer: the text opens a turn of its own.
        try makeEngine("basic", codex: "codex-steer-refused").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "turn running") { $0.chatEvents(bot.id).contains { label($0) == "userMessage" } }
        XCTAssertEqual(request(client, .send(botId: bot.id, text: "uno")), .ok)
        waitFor(client, "a new turn") { $0.chatEvents(bot.id).contains(.userMessage(text: "uno", promptId: "turn-2", origin: .chat)) }
        XCTAssertEqual(codexTexts("turn/steer"), ["uno@turn-1"])
        XCTAssertEqual(codexTexts("turn/start").last, "uno")
    }

    func testOneTextAtATimeKeepsTheOrderThroughARefusedSteer() throws {
        // A second text waits for the first one's answer, steer included: the refused steer goes first, as a new turn, and
        // the second steers that turn; nothing lost, nothing out of order.
        try makeEngine("basic", codex: "codex-steer-refused").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "turn running") { $0.chatEvents(bot.id).contains { label($0) == "userMessage" } }
        let ((first, _), (second, _)) = (client.send(.send(botId: bot.id, text: "uno")), client.send(.send(botId: bot.id, text: "due")))
        wait(for: [first, second], timeout: timeout)
        waitFor(client, "turn ended") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        let rpc = codexMessages().compactMap { m -> String? in
            guard let method = m["method"]?.string, method.hasPrefix("turn/") else { return nil }
            return method + " " + [m["params"]?["input"]?.array?.first?["text"]?.string, m["params"]?["expectedTurnId"]?.string].compactMap { $0 }.joined(separator: "@")
        }
        XCTAssertEqual(rpc.dropFirst(), ["turn/steer uno@turn-1", "turn/start uno", "turn/steer due@turn-2"])
        let said = client.all.chatEvents(bot.id).compactMap { if case let .userMessage(text, _, .chat) = $0 { text } else { nil } }
        XCTAssertEqual(said, ["uno", "due"])
    }

    func testMessageLostWithItsServerIsNotSentAgain() throws {
        // Sent, then the server died before answering: Codex may have taken it, so it is not sent again (a duplicate in the
        // thread); the chat says it may not have arrived, with the text.
        try makeEngine("basic", codex: "codex-lost-turn").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        XCTAssertEqual(request(client, .send(botId: bot.id, text: "Ancora?")), .ok)
        waitFor(client, "noted") { $0.chatEvents(bot.id).contains(.system(.messageMayNotHaveArrived(text: "Ancora?"))) }
        waitFor(client, "resumed") { $0.chatEvents(bot.id).contains(.system(.resumed)) }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(codexTexts("turn/start").filter { $0 == "Ancora?" }.count, 1)
    }

    func testStopWhileATurnStartsInterruptsItOnceItHasAnId() throws {
        // Stop pressed before Codex answered turn/start: the turn is interrupted as soon as its id arrives.
        try makeEngine("basic", codex: "codex-interrupt-early").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitUntil("turn starting") { [unowned self] in codexRequests("turn/start").count == 1 }
        XCTAssertEqual(request(client, .interrupt(botId: bot.id)), .ok)
        waitFor(client, "interrupted") { $0.chatEvents(bot.id).contains(.turnInterrupted) }
        XCTAssertEqual(codexRequests("turn/interrupt"), [["threadId": "thr-1", "turnId": "turn-1"]])
    }

    func testRefusedInterruptIsLogged() throws {
        try makeEngine("basic", codex: "codex-interrupt-refused").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "turn running") { $0.chatEvents(bot.id).contains { label($0) == "userMessage" } }
        XCTAssertEqual(request(client, .interrupt(botId: bot.id)), .ok)
        waitUntil("logged") { [unowned self] in
            ((try? String(contentsOf: paths.log, encoding: .utf8)) ?? "").contains("turn/interrupt refused: no active turn to interrupt")
        }
    }

    func testShutdownDuringCodexsCheckAnswersTheCatalogAndStartsNoServer() throws {
        // The catalog's reading waits for Codex's check: a shutdown meanwhile answers its waiters at once, and the check's
        // end starts no server.
        let (fake, fakeCodex) = (binDir.appendingPathComponent("fake-claude").path, binDir.appendingPathComponent("fake-codex").path)
        let engine = try makeEngine("basic", locate: { agent in
            if agent == .codex { Thread.sleep(forTimeInterval: 1) }         // a slow check
            return agent == .claude ? fake : fakeCodex
        })
        try engine.start()
        var answers: [CodexCatalog?] = []
        let answered = expectation(description: "answered")
        engine.queue.async { engine.codexCatalog { answers.append($0); answered.fulfill() } }
        shutdown(engine)
        wait(for: [answered], timeout: 0.5)
        XCTAssertEqual(answers.count, 1)
        XCTAssertNil(answers.first ?? nil)
        Thread.sleep(forTimeInterval: 1.5)          // the check has ended meanwhile
        XCTAssertNil(engine.queue.sync { engine.codexCatalogServer })
        XCTAssertFalse(((try? String(contentsOfFile: fakeLog, encoding: .utf8)) ?? "").contains("app-server"))
    }

    func testCodexBotRestartsForCodexPluginsOnly() throws {
        // The other half of testEachAgentRestartsForItsOwnPlugins: Claude Code's list leaves a Codex bot alone.
        try makeEngine("basic").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        guard case let .snapshot(snapshot) = request(client, .snapshot), var project = snapshot.projects.first
        else { return XCTFail("no project") }
        project.plugins = ["some-plugin@claude-marketplace"]
        guard case .project = request(client, .updateProject(project)) else { return XCTFail("project update refused") }
        Thread.sleep(forTimeInterval: 1.5)       // a relaunch would have started a second server by now
        XCTAssertEqual(try codexServers(bot).count, 1, "Claude Code plugins restarted a Codex bot")
        project.codexPlugins = ["browser@openai-bundled"]
        guard case .project = request(client, .updateProject(project)) else { return XCTFail("project update refused") }
        waitUntil("relaunched") { [unowned self] in (try? codexServers(bot).count) ?? 0 >= 2 }
        XCTAssertTrue(try XCTUnwrap(codexServers(bot).last).args.contains("plugins.browser@openai-bundled.enabled=true"))
    }

    func testCodexTerminalOpensAfterTheFirstTurn() throws {
        // Review Focus 5: before its first turn a thread cannot be shown; the terminal opens as soon as one started.
        let engine = try makeEngine("basic", codex: "codex-no-first-turn")
        try engine.start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "introduction refused") { $0.chatEvents(bot.id).contains(.turnFailed(reason: "Codex: busy")) }
        XCTAssertEqual(request(client, .attachTerminal(botId: bot.id)), .error(CodexText.terminalNotYet))
        XCTAssertFalse(try launches(1).contains { $0.args.first == "resume" })
        XCTAssertEqual(request(client, .send(botId: bot.id, text: "ciao")), .ok)
        waitFor(client, "thread kept") { $0.summaries(bot.id).contains { $0.bot.threadId == "thr-1" } }
        guard case .terminal = request(client, .attachTerminal(botId: bot.id)) else { return XCTFail("terminal refused") }
        waitFor(client, "terminal") { $0.terminalText.contains("CODEX-TUI thr-1 token") }
        let tui = try XCTUnwrap(launches(1).first { $0.args.first == "resume" })
        let server = try XCTUnwrap(codexServers(bot).last)
        XCTAssertEqual(tui.args, ["resume", "--remote", "ws://127.0.0.1:\(server.args[2].split(separator: ":").last!)",
                                  "--remote-auth-token-env", "SERIF_CODEX_TOKEN", "--no-alt-screen", "thr-1"])
        // The terminal holds the server's own secret.
        XCTAssertEqual(codexTokenHash(try XCTUnwrap(tui.env["SERIF_CODEX_TOKEN"])), server.args[server.args.firstIndex(of: "--ws-token-sha256")! + 1])
    }

    func testCodexTerminalRunsOnlyWhileShown() throws {
        let engine = try makeEngine("basic")
        try engine.start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        let running = { engine.queue.sync { engine.bots[bot.id]?.host.isRunning ?? false } }
        XCTAssertFalse(running())                        // no terminal until an app shows it (spec §4)
        guard case .terminal = request(client, .attachTerminal(botId: bot.id)) else { return XCTFail("terminal refused") }
        waitFor(client, "terminal") { $0.terminalText.contains("CODEX-TUI thr-1") }
        request(client, .terminalInput(botId: bot.id, data: Data("ping".utf8)))
        waitFor(client, "echo") { $0.terminalText.contains("ping") }
        XCTAssertEqual(request(client, .detachTerminal(botId: bot.id)), .ok)
        let stopped = expectation(description: "terminal stopped")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in if !running() { t.invalidate(); stopped.fulfill() } }
        wait(for: [stopped], timeout: timeout)
        poll.invalidate()
        XCTAssertEqual(client.all.summaries(bot.id).last?.state, .ready)      // the bot goes on without it
        // An app that goes away takes its terminal with it.
        let other = try connect()
        guard case .terminal = request(other, .attachTerminal(botId: bot.id)) else { return XCTFail("terminal refused") }
        XCTAssertTrue(running())
        other.close()
        let gone = expectation(description: "terminal stopped with the app")
        let poll2 = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in if !running() { t.invalidate(); gone.fulfill() } }
        wait(for: [gone], timeout: timeout)
        poll2.invalidate()
    }

    func testCodexTerminalSharedByTwoApps() throws {
        // Two apps showing it share one terminal; it stays while one of them still shows it, and its exit is logged.
        let engine = try makeEngine("basic")
        try engine.start()
        let (a, b) = (try connect(), try connect())
        let bot = try createBot(a, agent: .codex)
        waitFor(a, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        let running = { engine.queue.sync { engine.bots[bot.id]?.host.isRunning ?? false } }
        guard case .terminal = request(a, .attachTerminal(botId: bot.id)), case .terminal = request(b, .attachTerminal(botId: bot.id))
        else { return XCTFail("terminal refused") }
        waitFor(b, "terminal") { $0.terminalText.contains("CODEX-TUI thr-1") }
        XCTAssertEqual(request(a, .detachTerminal(botId: bot.id)), .ok)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(running(), "closed while another app shows it")
        XCTAssertEqual(try launches(3).filter { $0.args.first == "resume" }.count, 1)      // the catalog's server, the bot's, one terminal
        XCTAssertEqual(request(b, .detachTerminal(botId: bot.id)), .ok)
        waitUntil("terminal stopped") { !running() }
        waitUntil("exit logged") { [unowned self] in
            ((try? String(contentsOf: paths.log, encoding: .utf8)) ?? "").contains("Codex terminal exited")
        }
    }

    func testCodexTerminalShownAgainWhileClosingStartsAgain() throws {
        // An app that leaves the terminal and comes back at once (a view switched back, a reconnection) gets a running one
        // once the closing one has gone; the engine's shutdown leaves none behind.
        let engine = try makeEngine("basic")
        try engine.start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        guard case .terminal = request(client, .attachTerminal(botId: bot.id)) else { return XCTFail("terminal refused") }
        waitFor(client, "terminal") { $0.terminalText.contains("CODEX-TUI thr-1") }
        let ((left, _), (back, _)) = (client.send(.detachTerminal(botId: bot.id)), client.send(.attachTerminal(botId: bot.id)))
        wait(for: [left, back], timeout: timeout)
        // The catalog's server, the bot's, then two terminals.
        XCTAssertEqual(try launches(4).filter { $0.args.first == "resume" }.count, 2)
        waitUntil("running again") { engine.queue.sync { engine.bots[bot.id]?.host.isRunning ?? false } }
        shutdown(engine)
        XCTAssertFalse(engine.queue.sync { engine.bots[bot.id]?.host.isRunning ?? false })
    }

    func testCodexTerminalGoesWithItsServerAndItsBot() throws {
        // A server that dies takes its terminal along, the relaunched one brings it back for the app still showing it, and
        // an archived bot leaves none behind; even a terminal slow to go (killed 3 s after SIGTERM, past the relaunch).
        let engine = try makeEngine("basic", env: ["SERIF_FAKE_CODEX_TUI_STUBBORN": "1"])
        try engine.start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        let running = { engine.queue.sync { engine.bots[bot.id]?.host.isRunning ?? false } }
        guard case .terminal = request(client, .attachTerminal(botId: bot.id)) else { return XCTFail("terminal refused") }
        waitFor(client, "terminal") { $0.terminalText.contains("CODEX-TUI thr-1 token") }
        let pidFile = paths.bot(bot.id).dir.appendingPathComponent("codex.pid").path
        kill(try XCTUnwrap(pid_t(try String(contentsOfFile: pidFile, encoding: .utf8).split(separator: " ")[0])), SIGKILL)
        // A host runs one process at a time: the second terminal means the first has gone.
        waitFor(client, "terminal back") { $0.terminalText.components(separatedBy: "CODEX-TUI thr-1 token").count == 3 }
        XCTAssertEqual(request(client, .archiveBot(id: bot.id)), .ok)
        waitFor(client, "archived") { $0.summaries(bot.id).last?.state == .stopped }
        XCTAssertFalse(running())
    }

    func testCodexTerminalShownDuringARestartOpensOnTheNewServer() throws {
        // Shown while its bot restarts, the terminal waits for the new server: never one on the server going away.
        let engine = try makeEngine("basic")
        try engine.start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        let ((restarted, _), (shown, _)) = (client.send(.restartBot(id: bot.id)), client.send(.attachTerminal(botId: bot.id)))
        wait(for: [restarted, shown], timeout: timeout)
        XCTAssertFalse(engine.queue.sync { engine.bots[bot.id]?.host.isRunning ?? false }, "a terminal on the server going away")
        waitFor(client, "terminal") { $0.terminalText.contains("CODEX-TUI thr-1 token") }
        let server = try XCTUnwrap(codexServers(bot).last)
        XCTAssertEqual(try launches(1).filter { $0.args.first == "resume" }.map { $0.args[2] }, [server.args[2]])
    }

    func testCodexLeavesTheOtherThreadsOfItsServerAlone() throws {
        // The terminal can open another thread on the bot's server (/new, /resume): its events are not the bot's chat, its
        // turn is never steered, its requests are left to the terminal.
        try makeEngine("basic", codex: "codex-other-thread").start()
        let client = try connect()
        let bot = try createBot(client, agent: .codex)
        waitFor(client, "first turn") { $0.chatEvents(bot.id).contains { label($0) == "turnEnded" } }
        XCTAssertEqual(client.all.chatEvents(bot.id).map(label), ["system(botCreated)", "userMessage", "assistantText", "turnEnded"])
        XCTAssertTrue(client.all.openedRequests.isEmpty)
        XCTAssertEqual(request(client, .send(botId: bot.id, text: "Ancora")), .ok)
        waitUntil("a turn of its own") { [unowned self] in codexRequests("turn/start").count == 2 }
        XCTAssertTrue(codexRequests("turn/steer").isEmpty)
        XCTAssertFalse(codexMessages().contains { $0["id"] == 9 && $0["method"] == nil })     // neither answered nor refused
    }
}
