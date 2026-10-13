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
                           skills: [String] = [], plugins: [String] = []) throws -> Bot {
        let project: UUID
        if let projectId { project = projectId } else {
            guard case let .project(p) = request(client, .createProject(name: "P", linkedFolder: nil, readLinkedInstructions: true))
            else { throw XCTSkip("createProject failed") }
            project = p.id
        }
        let new = NewBot(projectId: project, name: "Bob", face: randomFace(existing: []), agent: agent, model: nil,
                         instructions: "Help.", freedom: .ask, skills: skills, plugins: plugins, connectors: connectors)
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
        XCTAssertEqual(start["sandbox"], "read-only")
        XCTAssertEqual(start["approvalPolicy"], "on-request")
        XCTAssertEqual(start["model"], "gpt-6-luna")                        // "Default" is Codex's default model
        XCTAssertTrue(start["developerInstructions"]?.string?.contains("AGENTS.md") ?? false)
        XCTAssertEqual(start["config"], ["sandbox_workspace_write": ["writable_roots": [.string(workspace), .string(paths.shared(bot.projectId).path)]]])
        XCTAssertEqual(codexRequests("experimentalFeature/list").first?["threadId"], "thr-1")
        XCTAssertEqual(codexRequests("mcpServerStatus/list").first?["threadId"], "thr-1")
        let link = paths.bot(bot.id).workspace.appendingPathComponent(".agents/skills/tidy").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), skill.path)
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
}
