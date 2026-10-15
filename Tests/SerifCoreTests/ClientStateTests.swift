import XCTest
@testable import SerifCore

final class ClientStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let face = BotFace(shape: .allCases[0], body: 0x6BC4A6, eyes: 0x14141A)

    private func summary(_ bot: Bot, state: BotState = .ready, lastEvent: ChatEventRecord? = nil) -> BotSummary {
        BotSummary(bot: bot, state: state, unread: false, lastEvent: lastEvent, preview: nil)
    }
    private func record(_ seq: Int, at: Double, _ event: ChatEvent) -> ChatEventRecord {
        ChatEventRecord(seq: seq, at: t0.addingTimeInterval(at), event: event)
    }
    private func user(_ text: String, origin: MessageOrigin = .chat) -> ChatEvent {
        .userMessage(text: text, promptId: nil, origin: origin)
    }

    func testSnapshotThenBotChangedAndWaitingCount() {
        let p = Project(name: "Work", createdAt: t0)
        let a = Bot(projectId: p.id, name: "Alpha", face: face, createdAt: t0)
        var s = ClientState()
        s.apply(snapshot: Snapshot(projects: [p], bots: [summary(a)], requests: [], engineVersion: "1"))
        XCTAssertTrue(s.connected)
        XCTAssertEqual(s.waitingCount, 0)
        s.apply(.botChanged(summary(a, state: .waiting(kind: .permission, requestId: UUID()))))
        XCTAssertEqual(s.waitingCount, 1)
        s.disconnected()
        XCTAssertFalse(s.connected)
        XCTAssertEqual(s.bots.count, 1)
    }

    func testChatEventOnlyAppendsToLoadedTranscript() {
        let p = Project(name: "Work", createdAt: t0)
        let a = Bot(projectId: p.id, name: "Alpha", face: face, createdAt: t0)
        let b = Bot(projectId: p.id, name: "Beta", face: face, createdAt: t0)
        var s = ClientState()
        s.apply(snapshot: Snapshot(projects: [p], bots: [summary(a), summary(b)], requests: [], engineVersion: "1"))
        s.transcripts[a.id] = Transcript()
        s.apply(.chatEvent(botId: a.id, record: record(1, at: 1, user("hi"))))
        s.apply(.chatEvent(botId: b.id, record: record(1, at: 2, user("yo"))))
        XCTAssertEqual(s.transcripts[a.id]?.lastSeq, 1)
        XCTAssertNil(s.transcripts[b.id])
        XCTAssertEqual(s.bots[b.id]?.lastEvent?.seq, 1)
    }

    func testRequestsOpenedAndClosed() {
        let bot = UUID()
        let req = PendingRequest(botId: bot, kind: .permission, toolName: "Bash", input: .object([:]),
                                 toolUseId: nil, promptId: nil, suggestions: nil)
        var s = ClientState()
        s.apply(.requestOpened(req))
        XCTAssertEqual(s.requests[req.id], req)
        s.apply(.requestClosed(requestId: req.id, botId: bot, resolution: .answeredInApp))
        XCTAssertTrue(s.requests.isEmpty)
    }

    func testProjectChangedUpserts() {
        var p = Project(name: "Work", createdAt: t0)
        var s = ClientState()
        s.apply(.projectChanged(p))
        p.name = "Renamed"
        s.apply(.projectChanged(p))
        XCTAssertEqual(s.projects.map(\.name), ["Renamed"])
    }

    func testPendingSendsTakenByMatchingChatMessage() {
        let p = Project(name: "Work", createdAt: t0)
        let a = Bot(projectId: p.id, name: "Alpha", face: face, createdAt: t0)
        var s = ClientState()
        s.apply(snapshot: Snapshot(projects: [p], bots: [summary(a)], requests: [], engineVersion: "1"))
        s.pendingSends[a.id] = ["one", "two", "one"]
        s.apply(.chatEvent(botId: a.id, record: record(1, at: 1, user("one", origin: .terminal))))
        XCTAssertEqual(s.pendingSends[a.id], ["one", "two", "one"])
        s.apply(.chatEvent(botId: a.id, record: record(2, at: 2, user("one"))))
        XCTAssertEqual(s.pendingSends[a.id], ["two", "one"])
    }

    func testPushWhileHistoryLoadsSurvivesTheOlderPage() {
        let bot = UUID()
        var s = ClientState()
        s.historyRequested(bot: bot)
        s.apply(.chatEvent(botId: bot, record: record(3, at: 3, user("new"))))
        s.historyLoaded([record(1, at: 1, user("old")), record(2, at: 2, user("older")), record(3, at: 3, user("new"))], bot: bot)
        let texts = s.transcripts[bot]?.items.compactMap { if case .user(_, let t, _, _, _) = $0 { t } else { nil } }
        XCTAssertEqual(texts, ["old", "older", "new"])
        XCTAssertEqual(s.transcripts[bot]?.firstSeq, 1)
        XCTAssertEqual(s.transcripts[bot]?.lastSeq, 3)
        // A second request (e.g. a retry) keeps what is there.
        s.historyRequested(bot: bot)
        XCTAssertEqual(s.transcripts[bot]?.lastSeq, 3)
    }

    func testPendingSendMatchesTrimmedText() {
        let bot = UUID()
        var s = ClientState()
        s.pendingSends[bot] = ["  hello\n"]
        s.apply(.chatEvent(botId: bot, record: record(1, at: 1, user("hello"))))
        XCTAssertEqual(s.pendingSends[bot], [])
    }

    func testSectionsFilterOrderAndPinned() {
        let work = Project(name: "Work", createdAt: t0)
        let home = Project(name: "Home", createdAt: t0.addingTimeInterval(1))
        let empty = Project(name: "Empty", createdAt: t0.addingTimeInterval(2))
        let gone = Project(name: "Gone", createdAt: t0.addingTimeInterval(3), archivedAt: t0)
        let old = Bot(projectId: work.id, name: "Old", face: face, createdAt: t0)
        let fresh = Bot(projectId: work.id, name: "Fresh", face: face, createdAt: t0.addingTimeInterval(10))
        let talked = Bot(projectId: work.id, name: "Talked", face: face, createdAt: t0.addingTimeInterval(5))
        let gardener = Bot(projectId: home.id, name: "Gardener", face: face, pinned: true, createdAt: t0)
        var archived = Bot(projectId: home.id, name: "Archived", face: face, pinned: true, createdAt: t0)
        archived.archivedAt = t0
        let ev = record(1, at: 100, user("x"))
        var s = ClientState()
        s.apply(snapshot: Snapshot(projects: [work, home, empty, gone],
                                   bots: [summary(old), summary(fresh), summary(talked, lastEvent: ev),
                                          summary(gardener), summary(archived)],
                                   requests: [], engineVersion: "1"))
        let all = s.sections(search: "")
        XCTAssertEqual(all.map(\.project.name), ["Work", "Home", "Empty"])
        XCTAssertEqual(all[0].bots.map(\.bot.name), ["Talked", "Fresh", "Old"])   // event 100 s > created +10 s
        XCTAssertEqual(all[1].bots.map(\.bot.name), ["Gardener"])
        XCTAssertEqual(s.sections(search: "gard").map(\.project.name), ["Home"])
        let byProject = s.sections(search: "WORK")
        XCTAssertEqual(byProject.map(\.project.name), ["Work"])
        XCTAssertEqual(byProject[0].bots.count, 3)
        XCTAssertTrue(s.sections(search: "zzz").isEmpty)
        XCTAssertEqual(s.pinned.map(\.bot.name), ["Gardener"])
    }

    func testRoutinesByProjectAndTheCardsWaitingForYou() {
        // Spec §4 and §7 of 0.6: the snapshot's routines land under their bot's project; the open cards of live bots count.
        let p = Project(name: "Work", createdAt: t0)
        let a = Bot(projectId: p.id, name: "Alpha", face: face, createdAt: t0)
        var gone = Bot(projectId: p.id, name: "Gone", face: face, createdAt: t0)
        gone.archivedAt = t0
        let tidy = Routine(botId: a.id, name: "Tidy", trigger: .every(minutes: 30), prompt: "x", createdBy: .user, createdAt: t0)
        let other = Routine(botId: UUID(), name: "Elsewhere", trigger: .every(minutes: 30), prompt: "x", createdBy: .user, createdAt: t0)
        let older = PendingRequest(botId: a.id, kind: .decision, toolName: "decision", input: [:], toolUseId: nil, promptId: nil,
                                   suggestions: nil, openedAt: t0)
        let newer = PendingRequest(botId: a.id, kind: .permission, toolName: "Bash", input: [:], toolUseId: nil, promptId: nil,
                                   suggestions: nil, openedAt: t0.addingTimeInterval(1))
        let archived = PendingRequest(botId: gone.id, kind: .permission, toolName: "Bash", input: [:], toolUseId: nil, promptId: nil,
                                      suggestions: nil, openedAt: t0)
        var s = ClientState()
        s.apply(snapshot: Snapshot(projects: [p], bots: [summary(a), summary(gone)], requests: [newer, archived, older],
                                   routines: [tidy, other], engineVersion: "1"))
        XCTAssertEqual(s.routines[p.id], [tidy])
        XCTAssertEqual(s.routines(of: a.id), [tidy])
        XCTAssertEqual(s.waitingForYou.map(\.id), [older.id, newer.id])
        var renamed = tidy; renamed.name = "Clean"
        s.apply(.routinesChanged(projectId: p.id, routines: [renamed]))
        XCTAssertEqual(s.routines(of: a.id), [renamed])
        s.apply(.requestClosed(requestId: older.id, botId: a.id, resolution: .answeredInApp, answer: .decision(option: 0, text: nil)))
        XCTAssertEqual(s.waitingForYou.map(\.id), [newer.id])
        XCTAssertEqual(s.waitingCount, 0)                 // the Dock badge still counts bots that wait, not cards
    }

    func testTiesBreakByNameAndArchivedDoNotWait() {
        let p = Project(name: "Work", createdAt: t0)
        let b = Bot(projectId: p.id, name: "Bravo", face: face, createdAt: t0)
        let a = Bot(projectId: p.id, name: "Alpha", face: face, createdAt: t0)
        var gone = Bot(projectId: p.id, name: "Gone", face: face, createdAt: t0)
        gone.archivedAt = t0
        let waiting = BotState.waiting(kind: .permission, requestId: UUID())
        var s = ClientState()
        s.apply(snapshot: Snapshot(projects: [p], bots: [summary(b), summary(a), summary(gone, state: waiting)],
                                   requests: [], engineVersion: "1"))
        XCTAssertEqual(s.sections(search: "")[0].bots.map(\.bot.name), ["Alpha", "Bravo"])
        XCTAssertEqual(s.waitingCount, 0)
    }
}
