import XCTest
@testable import SerifCore

final class MailTextTests: XCTestCase {
    private let (cody, milo, lead) = (UUID(), UUID(), UUID())
    private let utc = TimeZone(identifier: "UTC")!
    // 16 Oct 2026, 18:05 UTC
    private let deadline = Date(timeIntervalSince1970: 1_792_173_900)
    private func name(_ id: UUID) -> String { id == cody ? "Cody" : id == milo ? "Milo" : "Lea" }

    /// A box with task #1 (Cody → Milo) delivered, and whatever `then` does to it.
    private func box(_ then: (inout Mailbox) throws -> Void = { _ in }) throws -> Mailbox {
        var box = Mailbox()
        _ = try box.sendTask(from: cody, to: milo, text: "Check the logs", hours: 24, turnTask: nil,
                             at: deadline.addingTimeInterval(-24 * 3600))
        box.markDelivered(box.waiting(for: milo)[0].id, at: deadline)
        try then(&box)
        return box
    }

    private func text(_ m: MailMessage, _ box: Mailbox) -> String {
        mailTurnText(m, task: m.taskId.flatMap(box.task), name: name, timeZone: utc)
    }

    func testMailDate() { XCTAssertEqual(mailDate(deadline, timeZone: utc), "16 Oct 2026, 18:05") }

    func testTurnTexts() throws {
        var b = Mailbox()
        _ = try b.sendTask(from: cody, to: milo, text: "Check the logs", hours: 24, turnTask: nil,
                           at: deadline.addingTimeInterval(-24 * 3600))
        XCTAssertEqual(text(b.waiting(for: milo)[0], b), "Task #1 from Cody, a bot of this project (deadline 16 Oct 2026, 18:05). "
                       + "When done, call complete_task with task_id 1.\n\nCheck the logs")
        let done = try box { _ = try $0.complete(1, by: milo, result: "All clean", lead: lead, at: deadline) }
        XCTAssertEqual(text(done.waiting(for: cody)[0], done), "Reply from Milo to your task #1, now done:\n\nAll clean")
        XCTAssertEqual(text(done.waiting(for: lead)[0], done), "Task #1 (Cody → Milo) is done:\n\nAll clean")
        let asked = try box { try $0.sendMessage(from: milo, to: cody, kind: .reply, text: "Which day?", task: 1, at: deadline) }
        XCTAssertEqual(text(asked.waiting(for: cody)[0], asked), "Reply from Milo about task #1:\n\nWhich day?")
        let note = try box { try $0.sendMessage(from: cody, to: milo, kind: .note, text: "FYI", task: nil, at: deadline) }
        XCTAssertEqual(text(note.waiting(for: milo)[0], note), "Note from Cody:\n\nFYI")
    }

    func testNoticeTexts() throws {
        let byCody = try box { _ = try $0.cancel(1, by: cody, reason: "not needed", at: deadline) }
        XCTAssertEqual(text(byCody.waiting(for: milo)[0], byCody), "Task #1 from Cody was cancelled by Cody: not needed")
        let byUser = try box { _ = try $0.cancel(1, by: nil, reason: nil, at: deadline) }
        XCTAssertEqual(text(byUser.waiting(for: milo)[0], byUser), "Task #1 from Cody was cancelled by the user")
        XCTAssertEqual(text(byUser.waiting(for: cody)[0], byUser), "Task #1 to Milo was cancelled by the user")
        let expired = try box { _ = $0.expire(at: deadline) }
        XCTAssertEqual(text(expired.waiting(for: cody)[0], expired), "Task #1 to Milo expired without a reply")
        let archived = try box { _ = $0.archive(cody, at: deadline) }
        XCTAssertEqual(text(archived.waiting(for: milo)[0], archived), "Task #1 from Cody was cancelled: Cody was archived")
    }

    func testColleagues() {
        let p = UUID(), face = BotFace(shape: .allCases[0], body: 1, eyes: 2)
        let me = Bot(projectId: p, name: "Cody", face: face, instructions: "Leads the release.\nMore.")
        let made = Bot(projectId: p, name: "Milo", face: face, agent: .codex, instructions: "", createdBy: me.id)
        let gone = Bot(projectId: p, name: "Old", face: face, archivedAt: Date())
        XCTAssertEqual(colleaguesText([(me, .working(.thinking)), (made, .ready), (gone, .stopped)], caller: me.id, lead: me.id),
                       "Bots of this project:\n- Cody (you): Leads the release. [working, Claude Code, lead]\n"
                       + "- Milo [ready, Codex, created by you]")
    }

    func testInbox() throws {
        var b = try box()
        _ = try b.sendTask(from: milo, to: lead, text: "Ask Lea", hours: 24, turnTask: nil, at: deadline)
        _ = try b.sendMessage(from: cody, to: milo, kind: .note, text: "FYI", task: nil, at: deadline)
        let text = inboxText(b, for: milo, new: b.waiting(for: milo), name: name, now: deadline, timeZone: utc)
        XCTAssertEqual(text, """
            Open tasks given to you:
            - #1 from Cody, deadline 16 Oct 2026, 18:05: Check the logs

            Tasks you asked for:
            - #2 to Lea: open, deadline 17 Oct 2026, 18:05

            New messages:

            Note from Cody:

            FYI
            """)
        XCTAssertEqual(inboxText(Mailbox(), for: milo, new: [], name: name, now: deadline), "No open tasks and no new messages.")
    }
}
