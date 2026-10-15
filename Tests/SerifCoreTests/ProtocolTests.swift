import XCTest
@testable import SerifCore

final class ProtocolTests: XCTestCase {
    // Fractional seconds are exercised on purpose: the protocol must keep them.
    private let at = Date(timeIntervalSince1970: 1_791_000_000.125)
    private let botId = UUID()
    private let projectId = UUID()
    private let requestId = UUID()

    private var project: Project {
        Project(id: projectId, name: "Lavoro", createdAt: at, linkedFolder: "/Users/x/proj", readLinkedInstructions: true,
                skills: ["/s/tidy"], plugins: ["design"])
    }
    private var bot: Bot {
        Bot(id: botId, projectId: projectId, name: "Chief", face: BotFace(shape: .allCases[0], body: 0x6BC4A6, eyes: 0x14141A), createdAt: at,
            skills: ["/s/tidy"], plugins: ["superpowers@official"], connectors: true)
    }
    private var newBot: NewBot {
        NewBot(projectId: projectId, name: "Chief", face: bot.face, agent: .claude, model: "opus",
               instructions: "Be brief.", freedom: .edits, skills: ["/s/tidy"], plugins: ["design"], connectors: true)
    }
    private var request: PendingRequest {
        PendingRequest(id: requestId, botId: botId, kind: .permission, toolName: "Bash",
                       input: .object(["command": .string("ls")]), toolUseId: "toolu_1", promptId: "p1",
                       suggestions: .array([.string("allow ls")]), openedAt: at)
    }
    private var record: ChatEventRecord {
        ChatEventRecord(seq: 7, at: at, event: .assistantText(messageId: "m1", index: 0, delta: "ciao", final: false, promptId: "p1"))
    }

    private func assertRoundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try protocolEncoder().encode(value)
        XCTAssertEqual(try protocolDecoder().decode(T.self, from: data), value, file: file, line: line)
    }

    // MARK: Activity and requests

    func testSerifsToolsAreReadFromTheirSteps() {
        // Both agents name them "mcp__serif__<tool>" (spec §9).
        XCTAssertEqual(Activity.from(toolName: "mcp__serif__send_message", input: ["to": "Milo", "body": "x"]), .serif(.message(to: "Milo")))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__complete_task", input: ["task_id": "#17"]), .completeTask(17))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__cancel_task", input: ["task_id": 3]), .cancelTask(3))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__list_bots", input: [:]), .colleagues)
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__create_bot", input: ["name": "Milo"]), .createBot("Milo"))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__update_instructions", input: [:]), .updateInstructions(bot: nil))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__check_inbox", input: [:]), .inbox)
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__archive_bot", input: ["name": "Milo"]), .archiveBot("Milo"))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__update_instructions", input: ["bot": "Milo", "instructions": "x"]),
                       .updateInstructions(bot: "Milo"))
        // Missing arguments give the empty value, never a crash (task 0, empty name).
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__complete_task", input: ["result": "x"]), .completeTask(0))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__send_message", input: ["to": "", "body": "x"]), .message(to: ""))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__send_message", input: [:]), .message(to: ""))
        XCTAssertNil(SerifToolCall(toolName: "mcp__other__send_message", input: [:]))
        XCTAssertNil(SerifToolCall(toolName: "mcp__serif__make_coffee", input: [:]))
        XCTAssertEqual(Activity.from(toolName: "mcp__figma__get", input: [:]), .tool("mcp__figma__get"))
        // Routines, signals and decisions (spec §4–6 of 0.6).
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__create_routine", input: ["name": "Tidy", "every_minutes": 30]), .createRoutine("Tidy"))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__list_routines", input: [:]), .listRoutines)
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__set_routine_enabled", input: ["name": "Tidy", "enabled": false]),
                       .setRoutineEnabled(name: "Tidy", enabled: false))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__delete_routine", input: ["name": "Tidy"]), .deleteRoutine("Tidy"))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__run_routine", input: ["name": "Tidy"]), .runRoutine("Tidy"))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__emit_signal", input: ["name": "build-done"]), .emitSignal("build-done"))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__raise_decision", input: ["question": "Ship?"]), .raiseDecision)
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__list_decisions", input: [:]), .listDecisions)
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__withdraw_decision", input: ["number": "#5"]), .withdrawDecision(5))
        XCTAssertEqual(SerifToolCall(toolName: "mcp__serif__withdraw_decision", input: [:]), .withdrawDecision(0))
    }

    func testActivityFromTools() {
        XCTAssertEqual(Activity.from(toolName: "Bash", input: .object(["command": .string("ls"), "description": .string("List files")])), .runningCommand("List files"))
        XCTAssertEqual(Activity.from(toolName: "Bash", input: .object(["command": .string("ls")])), .runningCommand("ls"))
        XCTAssertEqual(Activity.from(toolName: "Read", input: .object(["file_path": .string("/a/b/notes.md")])), .reading("notes.md"))
        XCTAssertEqual(Activity.from(toolName: "Edit", input: .object(["file_path": .string("/x/y.swift")])), .editing("y.swift"))
        XCTAssertEqual(Activity.from(toolName: "Write", input: .object(["file_path": .string("/x/z.swift")])), .editing("z.swift"))
        XCTAssertEqual(Activity.from(toolName: "MultiEdit", input: .object(["file_path": .string("/x/w.swift")])), .editing("w.swift"))
        XCTAssertEqual(Activity.from(toolName: "NotebookEdit", input: .object(["notebook_path": .string("/n/nb.ipynb")])), .editing("nb.ipynb"))
        XCTAssertEqual(Activity.from(toolName: "Grep", input: .object([:])), .searching)
        XCTAssertEqual(Activity.from(toolName: "Glob", input: .object([:])), .searching)
        XCTAssertEqual(Activity.from(toolName: "WebFetch", input: .object([:])), .browsing)
        XCTAssertEqual(Activity.from(toolName: "WebSearch", input: .object([:])), .browsing)
        XCTAssertEqual(Activity.from(toolName: "Task", input: .object([:])), .delegating)
        XCTAssertEqual(Activity.from(toolName: "Agent", input: .object([:])), .delegating)
        XCTAssertEqual(Activity.from(toolName: "mcp__x__y", input: .object([:])), .tool("mcp__x__y"))
    }

    func testRequestKind() {
        XCTAssertEqual(PendingRequest.kind(forTool: "AskUserQuestion"), .question)
        XCTAssertEqual(PendingRequest.kind(forTool: "ExitPlanMode"), .plan)
        XCTAssertEqual(PendingRequest.kind(forTool: "Bash"), .permission)
    }

    func testEnvelopeIsOneLine() throws {
        let d = try protocolEncoder().encode(RequestEnvelope(id: 1, request: .send(botId: UUID(), text: "a\nb")))
        XCTAssertFalse(d.contains(UInt8(ascii: "\n")))
    }

    func testDecoderAcceptsDatesWithoutFractionalSeconds() throws {
        let json = #"{"seq":1,"at":"2026-10-13T10:00:00Z","event":{"turnInterrupted":{}}}"#
        let decoded = try protocolDecoder().decode(ChatEventRecord.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.at, Date(timeIntervalSince1970: 1_791_885_600))
        XCTAssertEqual(decoded.event, .turnInterrupted)
    }

    func testChatEventsRoundTrip() throws {
        let events: [ChatEvent] = [
            .userMessage(text: "ciao", promptId: "p1", origin: .terminal),
            .userMessage(text: "Introduce yourself.", promptId: "p0", origin: .introduction),
            .system(.introductionRequested),
            .assistantText(messageId: "m1", index: 2, delta: "x", final: true, promptId: nil),
            .assistantTextReplaced(messageId: "m1", text: "y"),
            .toolStarted(toolUseId: "t1", name: "Bash", input: .object(["command": .string("ls")]), promptId: "p1"),
            .toolFinished(toolUseId: "t1", ok: false, output: "err", durationMs: 42),
            .requestOpened(request),
            .requestClosed(requestId: requestId, resolution: .answeredInApp),
            .requestClosed(requestId: requestId, resolution: .answeredInApp, answer: .answers(["Colore?": ["Rosso"]])),
            .turnEnded(promptId: "p1", lastMessage: "fatto"),
            .turnFailed(reason: "boom"),
            .turnInterrupted,
            .subagent(started: true, agentType: "Explore"),
            .system(.linkedFolderMissing(path: "/x")),
            .system(.crashed(reason: "exit 1")),
        ]
        for event in events { try assertRoundTrip(event) }
        try assertRoundTrip(record)
    }

    func testCodexFieldsRoundTrip() throws {
        var codexBot = bot
        (codexBot.agent, codexBot.threadId) = (.codex, "thr-1")
        try assertRoundTrip(AppRequest.updateBot(codexBot))
        var codexProject = project
        codexProject.codexPlugins = ["browser@openai-bundled"]
        try assertRoundTrip(AppRequest.updateProject(codexProject))
        var card = request
        card.decisions = ["accept", "cancel"]
        try assertRoundTrip(Push.requestOpened(card))
        // A card stored before 0.4 has no decisions.
        let old = try protocolEncoder().encode(request)
        XCTAssertNil(try protocolDecoder().decode(PendingRequest.self, from: old).decisions)
    }

    func testMailFieldsAndEventsRoundTrip() throws {
        var created = bot
        created.createdBy = UUID()
        try assertRoundTrip(AppRequest.updateBot(created))
        var led = project
        led.leadBotId = botId
        try assertRoundTrip(AppRequest.updateProject(led))
        let events: [ChatEvent] = [
            .userMessage(text: "Task #3 from Cody", promptId: "p2", origin: .bot),
            .system(.createdBy(name: "Cody")),
            .mail(MailNote(messageId: UUID(), kind: .task, from: "Cody", to: "Milo", direction: .received, text: "Check the logs",
                           taskNumber: 3)),
            .mail(MailNote(messageId: UUID(), kind: .system, from: "Cody", to: "Milo", direction: .received,
                           text: "Task #3 from Cody was cancelled by the user", taskNumber: 3, notice: .cancelledByUser)),
            .task(TaskCard(number: 3, from: "Cody", to: "Milo", text: "Check the logs", deadline: at, status: .open)),
            .task(TaskCard(number: 3, from: "Cody", to: "Milo", text: "Check the logs", deadline: at, status: .done, result: "Clean")),
        ]
        for event in events { try assertRoundTrip(event) }
    }

    func testRequestAnswersRoundTrip() throws {
        let answers: [RequestAnswer] = [
            .allow, .allowSession, .deny(message: nil), .denyAndStop, .answers(["Quale?": ["A", "B"]]),
            .approvePlan, .rejectPlan(message: "no"), .decision(option: 1, text: nil), .decision(option: nil, text: "later"),
        ]
        for answer in answers { try assertRoundTrip(answer) }
    }

    func testRoutinesAndDecisionsRoundTrip() throws {
        // Spec §4–7 of 0.6: the new requests, pushes, events and the snapshot's routines.
        let routine = Routine(botId: botId, name: "Rassegna", trigger: .weekdaysAt(days: [1, 3], hour: 9, minute: 0), prompt: "Read",
                              createdBy: .bot, createdAt: at, lastRunAt: at, lastOutcome: .done,
                              pending: PendingRun(dueAt: at, signal: RunSignal(name: "go", text: nil, from: "Cody", chain: 1)), runs: 2)
        try assertRoundTrip(AppRequest.saveRoutine(routine))
        try assertRoundTrip(AppRequest.deleteRoutine(id: routine.id))
        try assertRoundTrip(AppRequest.runRoutine(id: routine.id))
        try assertRoundTrip(Push.routinesChanged(projectId: projectId, routines: [routine]))
        try assertRoundTrip(ResponseBody.snapshot(Snapshot(projects: [project], bots: [], requests: [], routines: [routine],
                                                           engineVersion: SerifVersion.current)))
        let card = PendingRequest(id: requestId, botId: botId, kind: .decision, toolName: "decision",
                                  input: ["number": 5, "question": "Ship?", "options": ["Yes", "No"]], toolUseId: nil, promptId: nil,
                                  suggestions: nil, openedAt: at)
        let run = RoutineRun(routineId: routine.id, name: "Rassegna", startedAt: at, maxMinutes: 30, notifies: false,
                             signal: routine.pending?.signal)
        let events: [ChatEvent] = [
            .userMessage(text: "Routine «Rassegna»", promptId: "p3", origin: .routine),
            .routineRun(run),
            .routineRun(RoutineRun(routineId: routine.id, name: "Rassegna", startedAt: at, maxMinutes: 30, notifies: true, outcome: .stopped)),
            .requestOpened(card),
            .requestClosed(requestId: requestId, resolution: .answeredInApp, answer: .decision(option: 0, text: "go")),
            .mail(MailNote(messageId: UUID(), kind: .system, from: nil, to: "Cody", direction: .received,
                           text: "Your decision on #5 «Ship?»: Yes — go")),
        ]
        for event in events { try assertRoundTrip(event) }
        // A mail note written by 0.5 has a sender; one from you has none.
        let old = #"{"messageId":"\#(requestId.uuidString)","kind":"note","from":"Cody","to":"Milo","direction":"sent","text":"hi"}"#
        XCTAssertEqual(try JSONDecoder().decode(MailNote.self, from: Data(old.utf8)).from, "Cody")
    }

    func testBotStatesRoundTrip() throws {
        let states: [BotState] = [
            .starting, .ready, .working(.runningCommand(nil)), .working(.tool("mcp__x")),
            .working(.serif(.message(to: "Milo"))), .working(.serif(.updateInstructions(bot: nil))),
            .waiting(kind: .question, requestId: requestId), .rateLimited(until: at), .rateLimited(until: nil),
            .crashed(reason: "x", retryAt: at), .stopped,
        ]
        for state in states { try assertRoundTrip(state) }
    }

    // MARK: AppRequest

    func testAppRequestHello() throws { try assertRoundTrip(AppRequest.hello(protocolVersion: 1)) }
    func testAppRequestSnapshot() throws { try assertRoundTrip(AppRequest.snapshot) }
    func testAppRequestCreateProject() throws {
        try assertRoundTrip(AppRequest.createProject(name: "Lavoro", linkedFolder: nil, readLinkedInstructions: false))
    }
    func testAppRequestUpdateProject() throws { try assertRoundTrip(AppRequest.updateProject(project)) }
    func testAppRequestArchiveProject() throws { try assertRoundTrip(AppRequest.archiveProject(id: projectId)) }
    func testAppRequestCreateBot() throws { try assertRoundTrip(AppRequest.createBot(newBot)) }
    func testAppRequestUpdateBot() throws { try assertRoundTrip(AppRequest.updateBot(bot)) }
    func testAppRequestArchiveBot() throws { try assertRoundTrip(AppRequest.archiveBot(id: botId)) }
    func testAppRequestRestartBot() throws { try assertRoundTrip(AppRequest.restartBot(id: botId)) }
    func testAppRequestHistory() throws {
        try assertRoundTrip(AppRequest.history(botId: botId, beforeSeq: nil, limit: 50))
        try assertRoundTrip(AppRequest.history(botId: botId, beforeSeq: 12, limit: 50))
    }
    func testAppRequestSend() throws { try assertRoundTrip(AppRequest.send(botId: botId, text: "a\nb")) }
    func testAppRequestInterrupt() throws { try assertRoundTrip(AppRequest.interrupt(botId: botId)) }
    func testAppRequestAnswer() throws { try assertRoundTrip(AppRequest.answer(requestId: requestId, answer: .deny(message: nil))) }
    func testAppRequestMarkRead() throws { try assertRoundTrip(AppRequest.markRead(botId: botId, seq: 7)) }
    func testAppRequestAttachTerminal() throws { try assertRoundTrip(AppRequest.attachTerminal(botId: botId)) }
    func testAppRequestDetachTerminal() throws { try assertRoundTrip(AppRequest.detachTerminal(botId: botId)) }
    func testAppRequestTerminalInput() throws {
        try assertRoundTrip(AppRequest.terminalInput(botId: botId, data: Data([0x1b, 0x5b, 0x41])))
    }
    func testAppRequestResizeTerminal() throws { try assertRoundTrip(AppRequest.resizeTerminal(botId: botId, cols: 120, rows: 40)) }
    func testAppRequestAgentStatus() throws {
        try assertRoundTrip(AppRequest.agentStatus(.claude))
        try assertRoundTrip(AppRequest.agentStatus(.codex))
    }
    func testAppRequestShutdown() throws { try assertRoundTrip(AppRequest.shutdown) }
    func testAppRequestCancelTask() throws { try assertRoundTrip(AppRequest.cancelTask(projectId: projectId, number: 17)) }

    // MARK: ResponseBody

    func testResponseOk() throws { try assertRoundTrip(ResponseBody.ok) }
    func testResponseWelcome() throws { try assertRoundTrip(ResponseBody.welcome(protocolVersion: 1, engineVersion: SerifVersion.current)) }
    func testResponseSnapshot() throws {
        let summary = BotSummary(bot: bot, state: .working(.thinking), unread: true, lastEvent: record, preview: "ciao")
        try assertRoundTrip(ResponseBody.snapshot(Snapshot(projects: [project], bots: [summary], requests: [request], engineVersion: SerifVersion.current)))
    }
    func testResponseProject() throws { try assertRoundTrip(ResponseBody.project(project)) }
    func testResponseBot() throws { try assertRoundTrip(ResponseBody.bot(bot)) }
    func testResponseHistory() throws { try assertRoundTrip(ResponseBody.history([record])) }
    func testResponseTerminal() throws { try assertRoundTrip(ResponseBody.terminal(seq: 3, data: Data([0, 1, 2, 255]))) }
    func testResponseAgentStatus() throws {
        try assertRoundTrip(ResponseBody.agentStatus(AgentStatus(agent: .claude, path: "/u/.local/bin/claude", version: "2.1.296",
                                                                   loggedIn: true, email: "a@b.c")))
        try assertRoundTrip(ResponseBody.agentStatus(AgentStatus(agent: .claude, path: nil, version: nil, loggedIn: nil, email: nil)))
        try assertRoundTrip(ResponseBody.agentStatus(AgentStatus(agent: .codex, path: "/c", version: "0.160.0", loggedIn: false, email: nil)))
    }
    func testResponseError() throws { try assertRoundTrip(ResponseBody.error("nope")) }

    // MARK: Push

    func testPushBotChanged() throws {
        try assertRoundTrip(Push.botChanged(BotSummary(bot: bot, state: .ready, unread: false, lastEvent: nil, preview: nil)))
    }
    func testPushProjectChanged() throws { try assertRoundTrip(Push.projectChanged(project)) }
    func testPushChatEvent() throws { try assertRoundTrip(Push.chatEvent(botId: botId, record: record)) }
    func testPushRequestOpened() throws { try assertRoundTrip(Push.requestOpened(request)) }
    func testPushRequestClosed() throws {
        try assertRoundTrip(Push.requestClosed(requestId: requestId, botId: botId, resolution: .cancelled))
    }
    func testPushRequestClosedWithAnswer() throws {
        try assertRoundTrip(Push.requestClosed(requestId: requestId, botId: botId, resolution: .answeredInApp, answer: .deny(message: "no")))
    }
    func testRequestClosedWithoutAnswerStillDecodes() throws {
        // A record written before the answer was stored.
        let old = #"{"requestClosed":{"requestId":"\#(requestId.uuidString)","resolution":"answeredInApp"}}"#
        XCTAssertEqual(try JSONDecoder().decode(ChatEvent.self, from: Data(old.utf8)),
                       .requestClosed(requestId: requestId, resolution: .answeredInApp, answer: nil))
    }
    func testPushTerminalOutput() throws { try assertRoundTrip(Push.terminalOutput(botId: botId, seq: 4, data: Data("ok".utf8))) }

    func testEngineMessageRoundTrip() throws {
        try assertRoundTrip(EngineMessage.response(id: 9, body: .ok))
        try assertRoundTrip(EngineMessage.push(.projectChanged(project)))
    }

    func testHookEnvelopeAndReplyRoundTrip() throws {
        try assertRoundTrip(HookEnvelope(botId: botId.uuidString, token: "t", payload: .object(["hook_event_name": .string("PreToolUse")])))
        try assertRoundTrip(HookReply(stdout: nil))
        try assertRoundTrip(HookReply(stdout: "{}"))
    }
}
