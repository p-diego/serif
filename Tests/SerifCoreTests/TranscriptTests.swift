import XCTest
@testable import SerifCore

final class TranscriptTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func rec(_ seq: Int, _ e: ChatEvent, after s: TimeInterval = 0) -> ChatEventRecord {
        ChatEventRecord(seq: seq, at: t0.addingTimeInterval(s + Double(seq)), event: e)
    }
    func tool(_ id: String) -> ChatEvent { .toolStarted(toolUseId: id, name: "Bash", input: .object(["command": .string("ls")]), promptId: nil) }
    func done(_ id: String, ok: Bool = true) -> ChatEvent { .toolFinished(toolUseId: id, ok: ok, output: "x", durationMs: 1) }
    func text(_ id: String, _ d: String, final: Bool = false) -> ChatEvent { .assistantText(messageId: id, index: 0, delta: d, final: final, promptId: nil) }
    func kinds(_ t: Transcript) -> [String] {
        t.items.map {
            switch $0 {
            case .timestamp: "ts"; case .user: "user"; case .assistant: "asst"; case .steps: "steps"; case .request: "req"
            case .system: "sys"; case .mail: "mail"; case .task: "task"
            }
        }
    }

    func testMailAndTaskCardsInPlace() {
        // The card shows where the task first appeared and changes there; the mail is an item of its own (spec §6).
        let open = TaskCard(number: 4, from: "Cody", to: "Milo", text: "Check", deadline: t0, status: .open)
        var done = open
        (done.status, done.result) = (.done, "Clean")
        let note = MailNote(messageId: UUID(), kind: .task, from: "Cody", to: "Milo", direction: .received, text: "Check", taskNumber: 4)
        var t = Transcript()
        t.apply([rec(1, .task(open)), rec(2, .mail(note)), rec(3, .userMessage(text: "Task #4 from Cody", promptId: "p", origin: .bot)),
                 rec(4, text("m", "ok", final: true)), rec(5, .task(done))])
        XCTAssertEqual(kinds(t), ["ts", "task", "mail", "asst"])
        XCTAssertEqual(t.items[1], .task(id: "task-4", card: done))
        XCTAssertEqual(t.items[2], .mail(id: "mail-2", note: note, at: t0.addingTimeInterval(2)))
    }

    func testTaskCardChangesInPlaceToCancelledAndExpired() {
        let open = TaskCard(number: 4, from: "Cody", to: "Milo", text: "Check", deadline: t0, status: .open)
        for status in [TaskStatus.cancelled, .expired] {
            var closed = open
            closed.status = status
            var t = Transcript()
            t.apply([rec(1, .task(open)), rec(2, text("m", "ok", final: true)), rec(3, .task(closed))])
            XCTAssertEqual(kinds(t), ["ts", "task", "asst"])
            XCTAssertEqual(t.items[1], .task(id: "task-4", card: closed))
        }
    }

    func testTwoTasksKeepSeparateCards() {
        let four = TaskCard(number: 4, from: "Cody", to: "Milo", text: "A", deadline: t0, status: .open)
        let five = TaskCard(number: 5, from: "Cody", to: "Ada", text: "B", deadline: t0, status: .open)
        var fiveDone = five
        fiveDone.status = .done
        var t = Transcript()
        t.apply([rec(1, .task(four)), rec(2, .task(five)), rec(3, .task(fiveDone))])
        XCTAssertEqual(kinds(t), ["ts", "task", "task"])
        XCTAssertEqual(t.items[1], .task(id: "task-4", card: four))              // untouched by #5's change
        XCTAssertEqual(t.items[2], .task(id: "task-5", card: fiveDone))
    }

    func testPrependKeepsTheLatestTaskStatus() {
        let open = TaskCard(number: 4, from: "Cody", to: "Milo", text: "A", deadline: t0, status: .open)
        var done = open
        done.status = .done
        let all = [rec(1, .task(open)), rec(2, text("m", "ok", final: true)), rec(3, .task(done))]
        var whole = Transcript(); whole.apply(all)
        var paged = Transcript(); paged.apply([all[2]])                          // only the last record loaded so far
        paged.prepend(Array(all[0...1]))                                         // the history arrives afterwards
        XCTAssertEqual(paged.items, whole.items)
        XCTAssertEqual(paged.items[1], .task(id: "task-4", card: done))
    }

    func testMailEchoIsNotShownAsYours() {
        // The text a bot gets from the mail is not the user's: the mail's own item shows it (spec §6).
        var t = Transcript()
        t.apply([rec(1, .userMessage(text: "Note from Cody:\n\nhi", promptId: "p1", origin: .bot))])
        XCTAssertEqual(kinds(t), [])
    }

    func testToolsGroupIntoOneSteps() {
        var t = Transcript()
        t.apply([rec(1, tool("a")), rec(2, tool("b")), rec(3, done("a")), rec(4, done("b"))])
        XCTAssertEqual(kinds(t), ["ts", "steps"])
        guard case .steps(let id, let steps, let status) = t.items[1] else { return XCTFail() }
        XCTAssertEqual(id, "steps-a"); XCTAssertEqual(steps.count, 2); XCTAssertEqual(status, .done)
    }

    func testTextSplitsGroupsAndStatus() {
        var t = Transcript()
        t.apply([rec(1, tool("a")), rec(2, text("m", "hi", final: true)), rec(3, tool("b")), rec(4, done("a", ok: false))])
        XCTAssertEqual(kinds(t), ["ts", "steps", "asst", "steps"])
        guard case .steps(_, _, let s1) = t.items[1], case .steps(_, _, let s2) = t.items[3] else { return XCTFail() }
        XCTAssertEqual(s1, .failed); XCTAssertEqual(s2, .running)
    }

    func testTimestampRule() {
        var t = Transcript()
        let u = ChatEvent.userMessage(text: "a", promptId: nil, origin: .chat)
        t.apply([rec(1, u), rec(2, u), rec(3, u, after: 16 * 60)])
        XCTAssertEqual(kinds(t), ["ts", "user", "user", "ts", "user"])
        XCTAssertEqual(t.items[0].id, "ts-1"); XCTAssertEqual(t.items[3].id, "ts-3")
    }

    func testStreamingAndReplace() {
        var t = Transcript()
        t.apply([rec(1, text("m", "he")), rec(2, text("m", "llo"))])
        guard case .assistant(_, let txt, _, let st) = t.items[1] else { return XCTFail() }
        XCTAssertEqual(txt, "hello"); XCTAssertTrue(st)
        t.apply(rec(3, .assistantTextReplaced(messageId: "m", text: "bye")))
        t.apply(rec(4, .turnEnded(promptId: nil, lastMessage: nil)))
        guard case .assistant(_, let txt2, _, let st2) = t.items[1] else { return XCTFail() }
        XCTAssertEqual(txt2, "bye"); XCTAssertFalse(st2)
    }

    func testQuestionAndPlanToolsAreNotSteps() {
        var t = Transcript()
        t.apply([rec(1, .toolStarted(toolUseId: "q", name: "AskUserQuestion", input: .null, promptId: nil)),
                 rec(2, .toolStarted(toolUseId: "p", name: "ExitPlanMode", input: .null, promptId: nil)),
                 rec(3, done("q")), rec(4, tool("a"))])
        XCTAssertEqual(kinds(t), ["ts", "steps"])
        guard case .steps(_, let steps, _) = t.items[1] else { return XCTFail() }
        XCTAssertEqual(steps.map(\.id), ["a"])
    }

    func testRequestResolution() {
        let r = PendingRequest(botId: UUID(), kind: .permission, toolName: "Bash", input: .null, toolUseId: nil, promptId: nil, suggestions: nil, openedAt: t0)
        var t = Transcript()
        t.apply([rec(1, .requestOpened(r)), rec(2, .requestClosed(requestId: r.id, resolution: .answeredInApp, answer: .allowSession))])
        XCTAssertEqual(t.items[1], .request(id: r.id.uuidString, request: r, resolution: .answeredInApp, answer: .allowSession))
    }

    func testInterruptAndFailure() {
        var t = Transcript()
        t.apply([rec(1, tool("a")), rec(2, .turnInterrupted), rec(3, .turnFailed(reason: "boom"))])
        XCTAssertEqual(kinds(t), ["ts", "steps", "sys", "sys"])
        guard case .steps(_, _, let s) = t.items[1] else { return XCTFail() }
        XCTAssertEqual(s, .failed)
        guard case .system(_, let n, _) = t.items[3] else { return XCTFail() }
        XCTAssertEqual(n, .crashed(reason: "boom"))
    }

    func testTurnEndClosesStepsGroup() {
        var t = Transcript()
        t.apply([rec(1, tool("a")), rec(2, .turnEnded(promptId: nil, lastMessage: nil)), rec(3, tool("b"))])
        XCTAssertEqual(kinds(t), ["ts", "steps", "steps"])
    }

    func testEqualityIgnoresRecordHistory() {
        let u = ChatEvent.userMessage(text: "a", promptId: nil, origin: .chat)
        var a = Transcript(), b = Transcript()
        a.apply([rec(1, u), rec(2, .subagent(started: true, agentType: nil))])
        b.apply([rec(1, u), rec(2, .subagent(started: false, agentType: nil))])
        XCTAssertEqual(a, b)
    }

    func testStepTitle() {
        func title(_ i: JSONValue) -> String { Step(id: "1", name: "Read", input: i).title }
        XCTAssertEqual(title(.object(["description": .string("d"), "command": .string("c")])), "c")
        XCTAssertEqual(title(.object(["description": .string("d"), "prompt": .string("p")])), "d")
        XCTAssertEqual(title(.object(["command": .string("c")])), "c")
        XCTAssertEqual(title(.object(["file_path": .string("/a/b.txt")])), "b.txt")
        XCTAssertEqual(title(.null), "Read")
    }

    func testPrependIsIdempotentAndOrdered() {
        let u = ChatEvent.userMessage(text: "a", promptId: nil, origin: .chat)
        let all = (1...6).map { rec($0, u) }
        var whole = Transcript(); whole.apply(all)
        var paged = Transcript(); paged.apply(Array(all[3...]))
        paged.prepend(Array(all[1...4]))   // overlaps on purpose
        paged.prepend(Array(all[0...2]))
        XCTAssertEqual(paged.items, whole.items)
        XCTAssertEqual(paged.lastSeq, 6)
        paged.apply(all[5])                // already applied: ignored
        XCTAssertEqual(paged.items, whole.items)
    }

    func testEndToEndSession() throws {
        var n = ClaudeNormalizer(); var out: [(NormalizerOutput, Date)] = []
        for h in try recordedHooks(session: "542bb6ac") {
            let at = Date(timeIntervalSince1970: h.ts)
            out += n.ingest(h.payload, at: at).map { ($0, at) }
        }
        out += n.flush(now: .distantFuture).map { ($0, Date(timeIntervalSince1970: 0)) }
        var records: [ChatEventRecord] = []
        for case (.event(let e), let at) in out { records.append(ChatEventRecord(seq: records.count + 1, at: at, event: e)) }
        var t = Transcript(); t.apply(records)
        XCTAssertEqual(Array(kinds(t).prefix(5)), ["ts", "user", "asst", "steps", "asst"])
        XCTAssertEqual(Set(t.items.map(\.id)).count, t.items.count)
    }

    func testIntroductionShowsAsASystemLine() {
        var t = Transcript()
        t.apply([rec(1, .userMessage(text: "You have just been created.", promptId: "p0", origin: .introduction)),
                 rec(2, text("m", "Hi!", final: true))])
        XCTAssertEqual(kinds(t), ["ts", "sys", "asst"])
        guard case .system(_, let note, _) = t.items[1] else { return XCTFail() }
        XCTAssertEqual(note, .introductionRequested)
    }
}
