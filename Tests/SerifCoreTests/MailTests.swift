import XCTest
@testable import SerifCore

final class MailTests: XCTestCase {
    private let (cody, milo, ada, lead) = (UUID(), UUID(), UUID(), UUID())
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testATaskOpensWithItsMessage() throws {
        var box = Mailbox()
        let task = try box.sendTask(from: cody, to: milo, text: "Check the logs", hours: nil, turnTask: nil, at: t0)
        XCTAssertEqual(task.number, 1)
        XCTAssertEqual(task.deadline, t0.addingTimeInterval(24 * 3600))            // 24 hours unless asked (spec §5)
        XCTAssertEqual(task.chain, [])
        XCTAssertEqual(box.waiting(for: milo).map(\.kind), [.task])
        XCTAssertEqual(box.waiting(for: milo).first?.taskId, 1)
        XCTAssertFalse(box.delivered(task: 1))
        box.markDelivered(box.waiting(for: milo)[0].id, at: t0)
        XCTAssertTrue(box.delivered(task: 1))
        XCTAssertEqual(try box.sendTask(from: cody, to: ada, text: "x", hours: 168, turnTask: nil, at: t0).number, 2)
    }

    func testDeadlineAndSizeLimits() {
        var box = Mailbox()
        for hours in [0, 169] {
            XCTAssertThrowsError(try box.sendTask(from: cody, to: milo, text: "x", hours: hours, turnTask: nil, at: t0)) {
                XCTAssertEqual($0 as? MailError, MailError("deadline_hours must be between 1 and 168"))
            }
        }
        let biggest = String(repeating: "é", count: 32_768)                         // 65 536 bytes of UTF-8
        XCTAssertNoThrow(try box.sendMessage(from: cody, to: milo, kind: .note, text: biggest, task: nil, at: t0))
        XCTAssertThrowsError(try box.sendMessage(from: cody, to: milo, kind: .note, text: biggest + "a", task: nil, at: t0))
    }

    func testEveryTextIsLimitedTo64KB() throws {
        var box = Mailbox()
        let biggest = String(repeating: "é", count: 32_768), tooBig = biggest + "a"
        XCTAssertNoThrow(try box.sendTask(from: cody, to: milo, text: biggest, hours: nil, turnTask: nil, at: t0))
        XCTAssertThrowsError(try box.sendTask(from: cody, to: milo, text: tooBig, hours: nil, turnTask: nil, at: t0))
        XCTAssertNoThrow(try box.complete(1, by: milo, result: biggest, lead: nil, at: t0))
        _ = try box.sendTask(from: cody, to: milo, text: "x", hours: nil, turnTask: nil, at: t0)
        XCTAssertThrowsError(try box.complete(2, by: milo, result: tooBig, lead: nil, at: t0))
        XCTAssertThrowsError(try box.cancel(2, by: cody, reason: tooBig, at: t0))
        XCTAssertEqual(box.task(2)?.status, .open)                                  // a refused cancel changes nothing
        XCTAssertNoThrow(try box.cancel(2, by: cody, reason: biggest, at: t0))
    }

    func testDeliveredMessagesAreKeptEightDays() throws {
        var box = Mailbox()
        _ = try box.sendMessage(from: cody, to: milo, kind: .note, text: "old", task: nil, at: t0)
        _ = try box.sendMessage(from: cody, to: milo, kind: .note, text: "recent", task: nil, at: t0)
        _ = try box.sendMessage(from: cody, to: milo, kind: .note, text: "waiting", task: nil, at: t0)
        let ids = box.messages.map(\.id)
        box.markDelivered(ids[0], at: t0)
        box.markDelivered(ids[1], at: t0.addingTimeInterval(2))
        _ = box.expire(at: t0.addingTimeInterval(8 * 86_400))                      // exactly 8 days: kept
        XCTAssertEqual(box.messages.count, 3)
        _ = box.expire(at: t0.addingTimeInterval(8 * 86_400 + 1))                  // 8 days + 1 s: the first goes
        XCTAssertEqual(box.messages.map(\.text), ["recent", "waiting"])
        _ = box.expire(at: t0.addingTimeInterval(40 * 86_400))                     // undelivered stays; tasks never go
        XCTAssertEqual(box.messages.map(\.text), ["waiting"])
        let task = try box.sendTask(from: cody, to: milo, text: "t", hours: nil, turnTask: nil, at: t0)
        _ = box.expire(at: t0.addingTimeInterval(400 * 86_400))
        XCTAssertEqual(box.task(task.number)?.status, .expired)
    }

    func testThreeOpenTasksForWhoAsksNoneForWhoReceives() throws {
        var box = Mailbox()
        for _ in 0..<3 { _ = try box.sendTask(from: cody, to: milo, text: "x", hours: nil, turnTask: nil, at: t0) }
        XCTAssertThrowsError(try box.sendTask(from: cody, to: ada, text: "x", hours: nil, turnTask: nil, at: t0))
        XCTAssertNoThrow(try box.sendTask(from: ada, to: milo, text: "x", hours: nil, turnTask: nil, at: t0))
        _ = try box.complete(1, by: milo, result: "ok", lead: nil, at: t0)            // a closed one frees a place
        XCTAssertNoThrow(try box.sendTask(from: cody, to: ada, text: "x", hours: nil, turnTask: nil, at: t0))
    }

    func testChainsComeFromTheTurnTaskAtMostFourAndNeverBack() throws {
        var box = Mailbox()
        let (d1, d2) = (UUID(), UUID())
        let t1 = try box.sendTask(from: cody, to: milo, text: "1", hours: nil, turnTask: nil, at: t0)
        let t2 = try box.sendTask(from: milo, to: ada, text: "2", hours: nil, turnTask: t1.number, at: t0)
        XCTAssertEqual(t2.chain, [1])
        // Never back up the chain: Cody asked for #1, Milo for #2.
        XCTAssertThrowsError(try box.sendTask(from: ada, to: cody, text: "x", hours: nil, turnTask: t2.number, at: t0))
        XCTAssertThrowsError(try box.sendTask(from: ada, to: milo, text: "x", hours: nil, turnTask: t2.number, at: t0))
        let t3 = try box.sendTask(from: ada, to: d1, text: "3", hours: nil, turnTask: t2.number, at: t0)
        let t4 = try box.sendTask(from: d1, to: d2, text: "4", hours: nil, turnTask: t3.number, at: t0)
        XCTAssertEqual(t4.chain, [1, 2, 3])
        XCTAssertThrowsError(try box.sendTask(from: d2, to: UUID(), text: "5", hours: nil, turnTask: t4.number, at: t0)) {
            XCTAssertTrue(($0 as? MailError)?.text.contains("chain of 5 tasks") ?? false)
        }
        // A turn not started by a task starts a new chain.
        XCTAssertEqual(try box.sendTask(from: d2, to: cody, text: "x", hours: nil, turnTask: nil, at: t0).chain, [])
    }

    func testAReplyNeedsAnOpenTaskBetweenTheTwo() throws {
        var box = Mailbox()
        XCTAssertThrowsError(try box.sendMessage(from: milo, to: cody, kind: .reply, text: "?", task: nil, at: t0))
        _ = try box.sendTask(from: cody, to: milo, text: "x", hours: nil, turnTask: nil, at: t0)
        XCTAssertThrowsError(try box.sendMessage(from: ada, to: cody, kind: .reply, text: "?", task: 1, at: t0))
        let reply = try box.sendMessage(from: milo, to: cody, kind: .reply, text: "Which logs?", task: 1, at: t0)
        XCTAssertEqual(reply.taskId, 1)
        XCTAssertNil(try box.sendMessage(from: milo, to: cody, kind: .note, text: "hi", task: 1, at: t0).taskId)
        _ = try box.cancel(1, by: cody, reason: nil, at: t0)
        XCTAssertThrowsError(try box.sendMessage(from: milo, to: cody, kind: .reply, text: "?", task: 1, at: t0)) {
            XCTAssertEqual($0 as? MailError, MailError("task #1 is already cancelled"))
        }
    }

    func testOnlyTheRecipientCompletesAndTheLeadGetsACopy() throws {
        var box = Mailbox()
        _ = try box.sendTask(from: cody, to: milo, text: "x", hours: nil, turnTask: nil, at: t0)
        XCTAssertThrowsError(try box.complete(1, by: cody, result: "r", lead: lead, at: t0))
        let done = try box.complete(1, by: milo, result: "All clean", lead: lead, at: t0)
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.result, "All clean")
        XCTAssertEqual(box.waiting(for: cody).map(\.notice), [.done])
        XCTAssertEqual(box.waiting(for: cody).map(\.kind), [.reply])
        XCTAssertEqual(box.waiting(for: lead).map(\.kind), [.system])
        XCTAssertThrowsError(try box.complete(1, by: milo, result: "again", lead: nil, at: t0)) {
            XCTAssertEqual($0 as? MailError, MailError("task #1 is already done"))
        }
        // The lead who asked gets the reply only, no copy.
        _ = try box.sendTask(from: lead, to: milo, text: "y", hours: nil, turnTask: nil, at: t0)
        _ = try box.complete(2, by: milo, result: "r", lead: lead, at: t0)
        XCTAssertEqual(box.waiting(for: lead).filter { $0.taskId == 2 }.map(\.kind), [.reply])
        XCTAssertThrowsError(try box.complete(9, by: milo, result: "r", lead: nil, at: t0)) {
            XCTAssertEqual($0 as? MailError, MailError("there is no task #9"))
        }
    }

    func testCancelByTheRequesterOrTheUser() throws {
        var box = Mailbox()
        _ = try box.sendTask(from: cody, to: milo, text: "x", hours: nil, turnTask: nil, at: t0)
        box.markDelivered(box.waiting(for: milo)[0].id, at: t0)
        XCTAssertThrowsError(try box.cancel(1, by: milo, reason: nil, at: t0))       // only the bot that asked
        _ = try box.cancel(1, by: cody, reason: "not needed", at: t0)
        XCTAssertEqual(box.waiting(for: milo).map(\.notice), [.cancelledByRequester])
        XCTAssertEqual(box.waiting(for: milo).first?.text, "not needed")
        XCTAssertEqual(box.waiting(for: cody), [])
        // The user's Cancel tells both.
        _ = try box.sendTask(from: cody, to: milo, text: "y", hours: nil, turnTask: nil, at: t0)
        box.markDelivered(box.waiting(for: milo).first { $0.taskId == 2 }!.id, at: t0)
        _ = try box.cancel(2, by: nil, reason: nil, at: t0)
        XCTAssertEqual(box.waiting(for: milo).filter { $0.taskId == 2 }.map(\.notice), [.cancelledByUser])
        XCTAssertEqual(box.waiting(for: cody).map(\.notice), [.cancelledByUser])
    }

    func testARecipientThatNeverGotTheTaskHearsNothing() throws {
        var box = Mailbox()
        _ = try box.sendTask(from: cody, to: milo, text: "x", hours: nil, turnTask: nil, at: t0)   // Milo still busy
        _ = try box.cancel(1, by: cody, reason: nil, at: t0)
        XCTAssertEqual(box.waiting(for: milo), [])
    }

    func testExpiredTasksTellTheirRequester() throws {
        var box = Mailbox()
        _ = try box.sendTask(from: cody, to: milo, text: "x", hours: 1, turnTask: nil, at: t0)
        XCTAssertEqual(box.expire(at: t0.addingTimeInterval(3599)), [])
        let expired = box.expire(at: t0.addingTimeInterval(3600))
        XCTAssertEqual(expired.map(\.status), [.expired])
        XCTAssertEqual(box.waiting(for: cody).map(\.notice), [.expired])
        XCTAssertEqual(box.waiting(for: milo), [])                                    // never delivered: dropped
        XCTAssertEqual(box.expire(at: t0.addingTimeInterval(7200)), [])               // once
    }

    func testThePurgeKeepsAnOpenTasksMessageUntilTheTaskIsClosed() throws {
        var box = Mailbox()
        _ = try box.sendTask(from: cody, to: milo, text: "x", hours: 1, turnTask: nil, at: t0)
        box.markDelivered(box.waiting(for: milo)[0].id, at: t0)
        let late = t0.addingTimeInterval(9 * 86_400)                    // the engine was off for 9 days
        XCTAssertEqual(box.expire(at: late).map(\.status), [.expired])
        XCTAssertTrue(box.delivered(task: 1))                           // the recipient's card can still be changed
        _ = box.expire(at: late.addingTimeInterval(60))                 // closed and old: purged now
        XCTAssertFalse(box.delivered(task: 1))
    }

    func testAnArchivedBotsMailIsDroppedAndItsTasksCancelled() throws {
        var box = Mailbox()
        _ = try box.sendTask(from: cody, to: milo, text: "given", hours: nil, turnTask: nil, at: t0)
        _ = try box.sendTask(from: milo, to: ada, text: "asked", hours: nil, turnTask: nil, at: t0)
        box.markDelivered(box.waiting(for: ada)[0].id, at: t0)
        let (closed, dropped) = box.archive(milo, at: t0)
        XCTAssertEqual(closed.map(\.number), [1, 2])
        XCTAssertEqual(closed.map(\.status), [.cancelled, .cancelled])
        XCTAssertEqual(dropped.map(\.taskId), [1])
        XCTAssertEqual(box.waiting(for: cody).map(\.notice), [.cancelledArchived])
        XCTAssertEqual(box.waiting(for: ada).map(\.notice), [.cancelledArchived])
        XCTAssertEqual(box.waiting(for: milo), [])
    }

    func testBotsAreNamedInAnyCaseOnce() throws {
        let p = UUID()
        func bot(_ name: String, archived: Bool = false) -> Bot {
            Bot(projectId: p, name: name, face: BotFace(shape: .allCases[0], body: 1, eyes: 2), archivedAt: archived ? t0 : nil)
        }
        let bots = [bot("Milo"), bot("Cody"), bot("cody "), bot("Old", archived: true)]
        XCTAssertEqual(try mailBot(named: "MILO", in: bots).name, "Milo")
        XCTAssertThrowsError(try mailBot(named: "Cody", in: bots)) {
            XCTAssertEqual($0 as? MailError, MailError("two bots are called Cody: rename one in Serif"))
        }
        XCTAssertThrowsError(try mailBot(named: "old", in: bots)) { XCTAssertEqual($0 as? MailError, MailError("Old is archived")) }
        XCTAssertThrowsError(try mailBot(named: "Zed", in: bots)) {
            XCTAssertEqual($0 as? MailError, MailError("no bot of this project is called Zed"))
        }
    }

    // MARK: - Decisions (spec §6 of 0.6)

    func testADecisionNeedsAQuestionAndTwoToSixShortOptions() throws {
        var box = Mailbox()
        let d = try box.raiseDecision(by: cody, question: " Ship 0.6 today? ", options: ["Yes", " No "], recommendation: 0,
                                      context: "Tests are green.", at: t0)
        XCTAssertEqual([d.number, d.recommendation], [1, 0])
        XCTAssertEqual(d.question, "Ship 0.6 today?")
        XCTAssertEqual(d.options, ["Yes", "No"])
        XCTAssertEqual(d.status, .open)
        XCTAssertEqual(box.decision(1), d)
        func refused(_ q: String = "Q?", _ options: [String] = ["A", "B"], recommendation: Int? = nil, context: String? = nil) -> String? {
            do { _ = try box.raiseDecision(by: cody, question: q, options: options, recommendation: recommendation, context: context, at: t0) }
            catch { return (error as? MailError)?.text }
            return nil
        }
        XCTAssertEqual(refused(" "), "raise_decision needs a question")
        XCTAssertEqual(refused(String(repeating: "q", count: 4097)), "the question is longer than 4 KB")
        XCTAssertEqual(refused("Q?", ["A"]), "give 2 to 6 options")
        XCTAssertEqual(refused("Q?", ["A", "B", "C", "D", "E", "F", "G"]), "give 2 to 6 options")
        XCTAssertEqual(refused("Q?", ["A", " "]), "each option must be 1 to 200 characters")
        XCTAssertEqual(refused("Q?", ["A", String(repeating: "b", count: 201)]), "each option must be 1 to 200 characters")
        XCTAssertEqual(refused("Q?", ["A", "B"], recommendation: 2), "recommendation must be the number of one of the options, 1 for the first")
        XCTAssertEqual(refused("Q?", ["A", "B"], context: String(repeating: "c", count: 4097)), "the context is longer than 4 KB")
        XCTAssertNil(refused("Q?", ["A", "B", "C", "D", "E", "F"], recommendation: 5, context: String(repeating: "c", count: 4096)))
        XCTAssertNil(refused())                                                        // the third open one
        XCTAssertEqual(refused(), "you already have 3 open decisions: wait for an answer, or withdraw one")
        XCTAssertNoThrow(try box.raiseDecision(by: milo, question: "Q?", options: ["A", "B"], recommendation: nil, context: nil, at: t0))
        XCTAssertEqual(box.decisions.filter { $0.botId == milo }.count, 1)           // the limit is per bot
    }

    func testAnAnswerGoesToTheBotAsMailFromTheUserAndToTheLead() throws {
        var box = Mailbox()
        _ = try box.raiseDecision(by: cody, question: "Ship 0.6 today?", options: ["Yes", "No"], recommendation: 0, context: nil, at: t0)
        XCTAssertThrowsError(try box.answerDecision(1, option: nil, text: " ", botName: "Cody", lead: nil, at: t0)) {
            XCTAssertEqual($0 as? MailError, MailError("choose an option or write an answer"))
        }
        XCTAssertThrowsError(try box.answerDecision(1, option: 2, text: nil, botName: "Cody", lead: nil, at: t0)) {
            XCTAssertEqual($0 as? MailError, MailError("there is no option 3"))
        }
        let answered = try box.answerDecision(1, option: 0, text: " after lunch ", botName: "Cody", lead: lead, at: t0)
        XCTAssertEqual(answered.status, .answered)
        XCTAssertEqual(answered.answer, DecisionAnswer(option: 0, text: "after lunch"))
        XCTAssertEqual(answered.answeredAt, t0)
        // From you (no sender), as a system message with the whole text; the lead gets the question and the answer.
        let toCody = box.waiting(for: cody)
        XCTAssertEqual(toCody.map(\.kind), [.system])
        XCTAssertNil(toCody.first?.from)
        XCTAssertEqual(toCody.first?.text, "Your decision on #1 «Ship 0.6 today?»: Yes — after lunch")
        XCTAssertEqual(box.waiting(for: lead).map(\.text), ["Decision #1 of Cody «Ship 0.6 today?» was answered by the user: Yes — after lunch"])
        XCTAssertThrowsError(try box.answerDecision(1, option: 1, text: nil, botName: "Cody", lead: nil, at: t0)) {
            XCTAssertEqual($0 as? MailError, MailError("decision #1 is already answered"))
        }
        // Words alone, an option alone; the lead who asked gets no copy.
        _ = try box.raiseDecision(by: lead, question: "Colour?", options: ["Red", "Blue"], recommendation: nil, context: nil, at: t0)
        _ = try box.answerDecision(2, option: nil, text: "Green, actually", botName: "Lea", lead: lead, at: t0)
        XCTAssertEqual(box.waiting(for: lead).map(\.text).last, "Your decision on #2 «Colour?»: Green, actually")
        XCTAssertEqual(box.waiting(for: lead).count, 2)
        _ = try box.raiseDecision(by: milo, question: "Font?", options: ["Serif", "Sans"], recommendation: 1, context: nil, at: t0)
        _ = try box.answerDecision(3, option: 1, text: nil, botName: "Milo", lead: nil, at: t0)
        XCTAssertEqual(box.waiting(for: milo).map(\.text), ["Your decision on #3 «Font?»: Sans"])
        XCTAssertThrowsError(try box.answerDecision(9, option: 0, text: nil, botName: "x", lead: nil, at: t0)) {
            XCTAssertEqual($0 as? MailError, MailError("there is no decision #9"))
        }
    }

    func testWithdrawnByItsBotOrByArchiving() throws {
        var box = Mailbox()
        _ = try box.raiseDecision(by: cody, question: "Q1?", options: ["A", "B"], recommendation: nil, context: nil, at: t0)
        _ = try box.raiseDecision(by: cody, question: "Q2?", options: ["A", "B"], recommendation: nil, context: nil, at: t0)
        _ = try box.raiseDecision(by: milo, question: "Q3?", options: ["A", "B"], recommendation: nil, context: nil, at: t0)
        XCTAssertThrowsError(try box.withdrawDecision(1, by: milo, reason: nil, at: t0)) {
            XCTAssertEqual($0 as? MailError, MailError("decision #1 is not yours"))
        }
        let gone = try box.withdrawDecision(1, by: cody, reason: "solved it", at: t0)
        XCTAssertEqual([gone.status.rawValue, gone.reason], ["withdrawn", "solved it"])
        XCTAssertEqual(box.waiting(for: cody), [])                                    // no mail for a withdrawal
        XCTAssertThrowsError(try box.withdrawDecision(1, by: cody, reason: nil, at: t0)) {
            XCTAssertEqual($0 as? MailError, MailError("decision #1 is already withdrawn"))
        }
        XCTAssertEqual(box.withdrawDecisions(of: cody, at: t0).map(\.number), [2])
        XCTAssertEqual(box.decisions.map(\.status), [.withdrawn, .withdrawn, .open])
        XCTAssertEqual(box.withdrawDecisions(of: cody, at: t0), [])
        // A blank context or reason is nothing: "withdrawn: " would render with nothing after it.
        let blank = try box.raiseDecision(by: cody, question: "Q4?", options: ["A", "B"], recommendation: nil, context: " \n", at: t0)
        XCTAssertNil(blank.context)
        XCTAssertNil(try box.withdrawDecision(blank.number, by: cody, reason: "  \n", at: t0).reason)
    }

    func testAMailJSONOfSerif05StillDecodes() throws {
        // As 0.5 wrote it: no decisions, no counter; a task's message with its sender.
        let json = #"""
        {"messages":[{"id":"33333333-3333-4333-8333-333333333333","from":"11111111-1111-4111-8111-111111111111",
                      "to":"22222222-2222-4222-8222-222222222222","kind":"task","text":"Check","taskId":1,
                      "createdAt":"2026-10-15T09:00:00.000Z"}],
         "tasks":[{"number":1,"from":"11111111-1111-4111-8111-111111111111","to":"22222222-2222-4222-8222-222222222222",
                   "text":"Check","deadline":"2026-10-16T09:00:00.000Z","status":"open","chain":[]}],
         "lastTask":1}
        """#
        let box = try protocolDecoder().decode(Mailbox.self, from: Data(json.utf8))
        XCTAssertEqual([box.messages.count, box.tasks.count, box.lastTask, box.decisions.count, box.lastDecision], [1, 1, 1, 0, 0])
        XCTAssertEqual(box.messages.first?.from?.uuidString, "11111111-1111-4111-8111-111111111111")
        // And an empty object is an empty mail.
        XCTAssertEqual(try protocolDecoder().decode(Mailbox.self, from: Data("{}".utf8)), Mailbox())
        // A decision without the fields added after it still decodes.
        let decision = #"""
        {"number":5,"botId":"11111111-1111-4111-8111-111111111111","question":"Q?","options":["A","B"],"status":"open",
         "createdAt":"2026-10-15T09:00:00.000Z","requestId":"44444444-4444-4444-8444-444444444444"}
        """#
        let d = try protocolDecoder().decode(Decision.self, from: Data(decision.utf8))
        XCTAssertNil(d.recommendation); XCTAssertNil(d.context); XCTAssertNil(d.answer); XCTAssertNil(d.reason)
        // Round trip with everything.
        var box2 = Mailbox()
        _ = try box2.raiseDecision(by: cody, question: "Q?", options: ["A", "B"], recommendation: 1, context: "why", at: t0)
        _ = try box2.answerDecision(1, option: 1, text: "ok", botName: "Cody", lead: lead, at: t0)
        let data = try protocolEncoder().encode(box2)
        XCTAssertEqual(try protocolDecoder().decode(Mailbox.self, from: data), box2)
    }

    func testABotCannotCreateTheThirteenthBotOfAProject() {
        // Spec §7 (author ruling 15/10): 12 active bots per project when a bot creates one; the user's sheet has no cap.
        XCTAssertEqual(maxBotsPerProject, 12)
        XCTAssertNil(createBotLimitError(activeBots: 0))
        XCTAssertNil(createBotLimitError(activeBots: 11))
        XCTAssertEqual(createBotLimitError(activeBots: 12), "this project already has 12 bots: ask the user to create more")
        XCTAssertEqual(createBotLimitError(activeBots: 40), "this project already has 12 bots: ask the user to create more")
    }
}
