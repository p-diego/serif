import XCTest
@testable import SerifCore

final class PresentationTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Rome")!; c.locale = Locale(identifier: "it_IT"); return c }
    private func date(_ d: Int, _ h: Int = 15, _ m: Int = 44) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }

    func testRowTime() {
        let now = date(12, 18, 0)    // Monday
        XCTAssertEqual(rowTime(date(12, 15, 44), now: now, calendar: cal, yesterday: "Y"), "15:44")
        XCTAssertEqual(rowTime(date(12, 8, 5), now: now, calendar: cal, yesterday: "Y"), "08:05")
        XCTAssertEqual(rowTime(date(11, 23, 0), now: now, calendar: cal, yesterday: "Y"), "Y")
        XCTAssertEqual(rowTime(date(10), now: now, calendar: cal, yesterday: "Y"), "sabato")
        XCTAssertEqual(rowTime(date(6), now: now, calendar: cal, yesterday: "Y"), "martedì")
        XCTAssertEqual(rowTime(date(5), now: now, calendar: cal, yesterday: "Y"), "5/10/26")
        XCTAssertEqual(rowTime(date(1), now: now, calendar: cal, yesterday: "Y"), "1/10/26")
    }

    func testMood() {
        XCTAssertEqual(mood(for: .working(.thinking), unread: false), .work)
        XCTAssertEqual(mood(for: .waiting(kind: .permission, requestId: UUID()), unread: true), .wait)
        XCTAssertEqual(mood(for: .ready, unread: true), .done)
        XCTAssertEqual(mood(for: .ready, unread: false), .watch)
        XCTAssertEqual(mood(for: .crashed(reason: "x", retryAt: nil), unread: false), .alarm)
        XCTAssertEqual(mood(for: .rateLimited(until: nil), unread: true), .alarm)
        XCTAssertEqual(mood(for: .starting, unread: false), .sleep)
        XCTAssertEqual(mood(for: .stopped, unread: false), .sleep)
    }

    func testAvatarLayoutBodyFillsAvatar() {
        for kind in MascotKind.allCases {
            let g = MascotGeometry.of(kind), (size, off) = avatarLayout(g, avatar: 44, inset: 8)
            let b = g.shape.body.boundingBoxOfPath
            let w = b.width * size.width / 100, h = b.height * size.height / 100
            XCTAssertEqual(max(w, h), 44, accuracy: 0.001, "\(kind)")
            XCTAssertEqual(off.x + b.midX * size.width / 100, 8 + 22, accuracy: 0.001)
            XCTAssertEqual(off.y + b.midY * size.height / 100, 8 + 22, accuracy: 0.001)
        }
    }

    func testRowPreview() {
        let bot = Bot(projectId: UUID(), name: "A", face: BotFace(shape: .allCases[0], body: 0, eyes: 0))
        func s(_ state: BotState, _ p: String?) -> BotSummary { BotSummary(bot: bot, state: state, unread: false, lastEvent: nil, preview: p) }
        XCTAssertEqual(rowPreview(s(.working(.typing), "old")), .typing)
        XCTAssertEqual(rowPreview(s(.waiting(kind: .permission, requestId: UUID()), "Run ls")), .waiting("Run ls"))
        XCTAssertEqual(rowPreview(s(.waiting(kind: .permission, requestId: UUID()), nil)), .waiting(nil))
        XCTAssertEqual(rowPreview(s(.crashed(reason: "boom", retryAt: nil), "x")), .crashed("boom"))
        XCTAssertEqual(rowPreview(s(.rateLimited(until: nil), nil)), .rateLimited)
        XCTAssertEqual(rowPreview(s(.ready, "Done.")), .text("Done."))
        XCTAssertEqual(rowPreview(s(.ready, nil)), .text(""))
        XCTAssertEqual(rowPreview(s(.ready, "**Il faro**\n\nI. `echo` _ciao_")), .text("Il faro\n\nI. echo ciao"))
        // The last thing that happened was mail: the row says so (spec §6).
        let note = MailNote(messageId: UUID(), kind: .note, from: "Cody", to: "A", direction: .received, text: "hi")
        let mailed = BotSummary(bot: bot, state: .ready, unread: false,
                                lastEvent: ChatEventRecord(seq: 3, at: Date(), event: .mail(note)), preview: "older reply")
        XCTAssertEqual(rowPreview(mailed), .mail(note))
    }

    private func step(_ name: String, _ input: [String: JSONValue] = [:]) -> Step { Step(id: UUID().uuidString, name: name, input: .object(input)) }

    func testStepsCountsAndKind() {
        let steps = [step("Bash"), step("Bash"), step("Bash"), step("Edit"), step("Write"), step("Read"), step("Grep"), step("WebFetch"), step("Foo")]
        XCTAssertEqual(stepsCounts(steps), StepsCounts(commands: 3, filesRead: 1, filesEdited: 2, searches: 1, other: 2))
        XCTAssertEqual(stepsKind(steps.prefix(3).map { $0 }), .commands)
        XCTAssertEqual(stepsKind([step("Edit"), step("Read"), step("Write")]), .files)
        XCTAssertEqual(stepsKind([step("Grep"), step("Glob")]), .search)
        XCTAssertEqual(stepsKind([step("WebSearch")]), .web)
        XCTAssertEqual(stepsKind([step("mcp__x__go")]), .mixed("mcp__x__go"))
        XCTAssertEqual(stepsKind([step("Bash"), step("Bash"), step("Bash"), step("Edit")]), .commands)    // majority
        XCTAssertEqual(stepsKind([step("Edit"), step("Bash"), step("Bash"), step("Bash"), step("Edit"), step("Edit")]), .files)
        XCTAssertEqual(stepsKind([step("Bash"), step("Edit")]), .commands)    // tie: the first step's kind
        XCTAssertEqual(stepsKind([step("Edit"), step("Bash")]), .files)
        XCTAssertEqual(stepsKind([]), .mixed(""))
    }
}

final class RequestSummaryTests: XCTestCase {
    private func req(_ tool: String, _ input: JSONValue) -> PendingRequest {
        PendingRequest(botId: UUID(), kind: PendingRequest.kind(forTool: tool), toolName: tool, input: input,
                       toolUseId: nil, promptId: nil, suggestions: nil)
    }

    func testSummaries() {
        XCTAssertEqual(requestSummary(req("Bash", .object(["command": .string("touch a.txt")]))), .command("touch a.txt"))
        XCTAssertEqual(requestSummary(req("Write", .object(["file_path": .string("/tmp/x/a.txt")]))), .file("a.txt"))
        XCTAssertEqual(requestSummary(req("Edit", .object(["file_path": .string("/tmp/x/b.swift")]))), .file("b.swift"))
        let q = JSONValue.object(["questions": .array([.object(["question": .string("Che colore preferisci?")])])])
        XCTAssertEqual(requestSummary(req("AskUserQuestion", q)), .question("Che colore preferisci?"))
        XCTAssertEqual(requestSummary(req("ExitPlanMode", .object(["plan": .string("# x")]))), .plan)
        XCTAssertEqual(requestSummary(req("WebFetch", .object([:]))), .tool("WebFetch"))
        XCTAssertEqual(requestSummary(req("Bash", .object([:]))), .tool("Bash"))
    }

    func testShouldNotify() {
        let bot = Bot(projectId: UUID(), name: "b", face: BotFace(shape: MascotKind.allCases[0], body: 0, eyes: 0))
        var quiet = bot; quiet.notifications = false
        let request = PendingRequest(botId: bot.id, kind: .permission, toolName: "Bash", input: .null, toolUseId: nil, promptId: nil, suggestions: nil)
        let events: [(ChatEvent, NotificationKind?)] = [
            (.requestOpened(request), .waiting),
            (.turnEnded(promptId: nil, lastMessage: "x"), .finished),
            (.turnFailed(reason: "boom"), .failed),
            (.turnFailed(reason: "rate_limit"), .rateLimited),
            (.turnFailed(reason: "Rate limit reached"), .rateLimited),
            (.turnInterrupted, nil),
            (.userMessage(text: "hi", promptId: nil, origin: .chat), nil),
            (.system(.compacted), nil),
            (.system(.crashed(reason: "Exit code 3")), .failed),
        ]
        for (event, kind) in events {
            XCTAssertEqual(shouldNotify(event: event, bot: bot, viewingBot: nil, windowKey: false), kind)
            // Looking at this bot with the window key silences it; another bot or a background window does not.
            XCTAssertNil(shouldNotify(event: event, bot: bot, viewingBot: bot.id, windowKey: true))
            XCTAssertEqual(shouldNotify(event: event, bot: bot, viewingBot: bot.id, windowKey: false), kind)
            XCTAssertEqual(shouldNotify(event: event, bot: bot, viewingBot: UUID(), windowKey: true), kind)
            XCTAssertNil(shouldNotify(event: event, bot: quiet, viewingBot: nil, windowKey: false))
        }
        // A turn the mail started ends quietly; its cards and errors still notify (spec §6).
        XCTAssertNil(shouldNotify(event: .turnEnded(promptId: nil, lastMessage: "x"), bot: bot, viewingBot: nil, windowKey: false,
                                  turnOrigin: .bot))
        XCTAssertEqual(shouldNotify(event: .requestOpened(request), bot: bot, viewingBot: nil, windowKey: false, turnOrigin: .bot),
                       .waiting)
        XCTAssertEqual(shouldNotify(event: .turnFailed(reason: "boom"), bot: bot, viewingBot: nil, windowKey: false, turnOrigin: .bot),
                       .failed)
    }
}
