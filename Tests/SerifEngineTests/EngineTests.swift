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
    private var binDir: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent() }

    // Unix socket paths must stay under 104 bytes: a short root in /tmp.
    override func setUp() { root = URL(fileURLWithPath: "/tmp/serif-e-\(UUID().uuidString.prefix(8))") }

    override func tearDown() {
        clients.forEach { $0.close() }
        for engine in engines { shutdown(engine) }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEngine(_ scenario: String) throws -> Engine {
        let scenarioPath = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/scenarios/\(scenario).jsonl").path
        let hook = binDir.appendingPathComponent("serif-hook").path
        let env = ["PATH": "/usr/bin:/bin", "SERIF_FAKE_SCENARIO": scenarioPath, "SERIF_HOOK_BIN": hook,
                   "SERIF_FAKE_LOG": fakeLog, "SERIF_FAKE_TRANSCRIPT": transcript, "CLAUDECODE": "1",
                   "CLAUDE_CONFIG_DIR": root.path + "/claude"]      // the engine's catalog: never the real ~/.claude
        let engine = try Engine(paths: paths, claudePath: binDir.appendingPathComponent("fake-claude").path,
                                hookCommand: hook, environment: env)
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

    /// A project and a bot in it; returns the bot as the engine created it.
    private func createBot(_ client: TestClient) throws -> Bot {
        guard case let .project(project) = request(client, .createProject(name: "P", linkedFolder: nil, readLinkedInstructions: true))
        else { throw XCTSkip("createProject failed") }
        let new = NewBot(projectId: project.id, name: "Bob", face: randomFace(existing: []), agent: .claude, model: nil,
                         instructions: "Help.", freedom: .ask)
        guard case let .bot(bot) = request(client, .createBot(new)) else { throw XCTSkip("createBot failed") }
        return bot
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
}
