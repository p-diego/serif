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

    func testABotCannotCreateTheThirteenthBotOfAProject() {
        // Spec §7 (author ruling 15/10): 12 active bots per project when a bot creates one; the user's sheet has no cap.
        XCTAssertEqual(maxBotsPerProject, 12)
        XCTAssertNil(createBotLimitError(activeBots: 0))
        XCTAssertNil(createBotLimitError(activeBots: 11))
        XCTAssertEqual(createBotLimitError(activeBots: 12), "this project already has 12 bots: ask the user to create more")
        XCTAssertEqual(createBotLimitError(activeBots: 40), "this project already has 12 bots: ask the user to create more")
    }
}
