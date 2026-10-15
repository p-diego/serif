import XCTest
import SerifCore
@testable import SerifEngine

final class StoreTests: XCTestCase {
    var root: URL!
    var paths: SerifPaths { SerifPaths(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("serif-store-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.stateFile.path)
        try? FileManager.default.removeItem(at: root) }

    // Whole milliseconds: the protocol date format keeps nothing finer.
    let t0 = Date(timeIntervalSince1970: 1_800_000_000.123)

    func event(_ n: Int) -> ChatEvent { .turnFailed(reason: "e\(n)") }

    func makeBot(_ project: Project) -> Bot { Bot(projectId: project.id, name: "b", face: randomFace(existing: []), createdAt: t0) }

    func testStateWrittenBy02Loads() throws {
        // Projects and bots as Serif 0.2 saved them: no skills, plugins or connectors. They start empty and off (spec §6.1).
        let state = #"""
        {"projects":[{"id":"11111111-1111-4111-8111-111111111111","name":"P","createdAt":"2026-10-12T10:00:00.000Z",
                      "readLinkedInstructions":true}],
         "bots":[{"id":"22222222-2222-4222-8222-222222222222","projectId":"11111111-1111-4111-8111-111111111111",
                  "name":"Bob","face":{"shape":"ball","body":15087423,"eyes":16119804,"eyeSize":1,"eyeLift":0,"eyeSpread":1},
                  "agent":"claude","instructions":"","freedom":"ask","sessionId":"33333333-3333-4333-8333-333333333333",
                  "notifications":true,"pinned":false,"createdAt":"2026-10-12T10:00:00.000Z"}]}
        """#
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(state.utf8).write(to: paths.stateFile)
        let store = try Store(paths: paths)
        let project = try XCTUnwrap(store.projects.first)
        XCTAssertEqual(project.skills, []); XCTAssertEqual(project.plugins, [])
        let bot = try XCTUnwrap(store.bots.first)
        XCTAssertEqual(bot.name, "Bob")
        XCTAssertEqual(bot.skills, []); XCTAssertEqual(bot.plugins, []); XCTAssertFalse(bot.connectors)
    }

    func testUnreadableStateThrows() throws {
        let store = try Store(paths: paths)
        try store.save(project: Project(name: "p", createdAt: t0))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: paths.stateFile.path)
        XCTAssertThrowsError(try Store(paths: paths))
    }

    func testSaveAndReload() throws {
        let store = try Store(paths: paths)
        let project = Project(name: "p", createdAt: t0)
        let bot = makeBot(project)
        try store.save(project: project); try store.save(bot: bot)
        var renamed = bot; renamed.name = "renamed"
        try store.save(bot: renamed)
        let again = try Store(paths: paths)
        XCTAssertEqual(again.projects, [project])
        XCTAssertEqual(again.bots, [renamed])
    }

    func appendThree(_ store: Store, _ bot: UUID) throws {
        for n in 1...3 { _ = try store.append(event(n), bot: bot, at: t0) }
    }

    func testAppendAssignsSeqAndMeta() throws {
        let store = try Store(paths: paths)
        let bot = UUID()
        var seqs: [Int] = []
        for n in 1...3 { seqs.append(try store.append(event(n), bot: bot, at: t0).seq) }
        XCTAssertEqual(seqs, [1, 2, 3])
        XCTAssertEqual(store.meta(bot).lastSeq, 3)
        XCTAssertEqual(try Store(paths: paths).meta(bot).lastSeq, 3)
    }

    func testHistoryPagingAndRecords() throws {
        let store = try Store(paths: paths)
        let bot = UUID()
        try appendThree(store, bot)
        XCTAssertEqual(try store.history(bot: bot, beforeSeq: nil, limit: 2).map(\.seq), [2, 3])
        XCTAssertEqual(try store.history(bot: bot, beforeSeq: 2, limit: 2).map(\.seq), [1])
        XCTAssertEqual(try store.records(bot: bot, afterSeq: 1).map(\.seq), [2, 3])
        XCTAssertEqual(try store.history(bot: bot, beforeSeq: nil, limit: 5).first?.at, t0)
    }

    func testCorruptLinesAreSkipped() throws {
        let store = try Store(paths: paths)
        let bot = UUID()
        try appendThree(store, bot)
        let handle = try FileHandle(forWritingTo: paths.bot(bot).events)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"seq\":4,\"at\":\"20".utf8)); try handle.close()
        XCTAssertEqual(try store.records(bot: bot, afterSeq: 0).map(\.seq), [1, 2, 3])
        XCTAssertEqual(try store.append(event(4), bot: bot, at: t0).seq, 4)
        XCTAssertEqual(try store.records(bot: bot, afterSeq: 0).map(\.seq), [1, 2, 3, 4])
    }

    func testReopenContinuesSeq() throws {
        let bot = UUID()
        try appendThree(try Store(paths: paths), bot)
        XCTAssertEqual(try Store(paths: paths).append(event(4), bot: bot, at: t0).seq, 4)
    }

    func testMissingMetaContinuesFromFile() throws {
        let bot = UUID()
        try appendThree(try Store(paths: paths), bot)
        try FileManager.default.removeItem(at: paths.bot(bot).meta)
        XCTAssertEqual(try Store(paths: paths).append(event(4), bot: bot, at: t0).seq, 4)
    }

    func testMetaRoundTripAndPrepareFolders() throws {
        let store = try Store(paths: paths)
        let project = Project(name: "p", createdAt: t0)
        let bot = makeBot(project)
        var meta = BotMeta(); meta.hasStarted = true; meta.crashCount = 2
        try store.setMeta(meta, for: bot.id)
        XCTAssertEqual(try Store(paths: paths).meta(bot.id), meta)
        try store.prepareFolders(for: bot)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.bot(bot.id).workspace.path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.shared(project.id).path, isDirectory: &isDir) && isDir.boolValue)
    }

    func testMailIsKeptPerProjectAndABadFileSetAside() throws {
        let (project, other) = (UUID(), UUID())
        var box = Mailbox()
        _ = try box.sendTask(from: UUID(), to: UUID(), text: "Check the logs", hours: nil, turnTask: nil, at: t0)
        try Store(paths: paths).save(box, project: project)
        XCTAssertEqual(paths.mail(project).deletingLastPathComponent(), paths.shared(project).deletingLastPathComponent())
        XCTAssertEqual(try Store(paths: paths).mailbox(project), box)              // read back by a new engine
        XCTAssertEqual(try Store(paths: paths).mailbox(other), Mailbox())
        // A file that does not decode: set aside, the mail starts empty (spec §10).
        try FileManager.default.createDirectory(at: paths.shared(other), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: paths.mail(other))
        XCTAssertEqual(try Store(paths: paths).mailbox(other), Mailbox())
        XCTAssertEqual(try String(contentsOf: paths.mail(other).appendingPathExtension("bad"), encoding: .utf8), "{")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.mail(other).path))
        XCTAssertTrue(try String(contentsOf: paths.log, encoding: .utf8).contains("mail.json.bad"))
    }

    func testAFailedMailSaveLeavesTheCachedMailAsItWas() throws {
        let project = UUID(), store = try Store(paths: paths)
        var box = Mailbox()
        _ = try box.sendTask(from: UUID(), to: UUID(), text: "x", hours: nil, turnTask: nil, at: t0)
        // A file where the project's folder should be: the write cannot happen.
        try FileManager.default.createDirectory(at: paths.mail(project).deletingLastPathComponent().deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: paths.mail(project).deletingLastPathComponent())
        XCTAssertThrowsError(try store.save(box, project: project))
        XCTAssertEqual(try store.mailbox(project), Mailbox())          // memory matches the disk, which has nothing
    }

    func testStateWrittenBy04Loads() throws {
        // As Serif 0.4 saved them: no lead, no creator (spec §7-8).
        let state = #"""
        {"projects":[{"id":"11111111-1111-4111-8111-111111111111","name":"P","createdAt":"2026-10-14T10:00:00.000Z",
                      "readLinkedInstructions":true,"skills":[],"plugins":[],"codexPlugins":[]}],
         "bots":[{"id":"22222222-2222-4222-8222-222222222222","projectId":"11111111-1111-4111-8111-111111111111",
                  "name":"Bob","face":{"shape":"ball","body":15087423,"eyes":16119804,"eyeSize":1,"eyeLift":0,"eyeSpread":1},
                  "agent":"codex","instructions":"","freedom":"ask","sessionId":"33333333-3333-4333-8333-333333333333",
                  "notifications":true,"pinned":false,"createdAt":"2026-10-14T10:00:00.000Z",
                  "skills":[],"plugins":[],"connectors":false,"threadId":"thr-1"}]}
        """#
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(state.utf8).write(to: paths.stateFile)
        let store = try Store(paths: paths)
        XCTAssertNil(try XCTUnwrap(store.projects.first).leadBotId)
        XCTAssertNil(try XCTUnwrap(store.bots.first).createdBy)
        XCTAssertEqual(store.bots.first?.threadId, "thr-1")
    }

    func testStateWrittenBy03Loads() throws {
        // As Serif 0.3 saved them: no Codex plugins, no thread (spec §6, §4).
        let state = #"""
        {"projects":[{"id":"11111111-1111-4111-8111-111111111111","name":"P","createdAt":"2026-10-12T10:00:00.000Z",
                      "readLinkedInstructions":true,"skills":["/s/tidy"],"plugins":["figma"]}],
         "bots":[{"id":"22222222-2222-4222-8222-222222222222","projectId":"11111111-1111-4111-8111-111111111111",
                  "name":"Bob","face":{"shape":"ball","body":15087423,"eyes":16119804,"eyeSize":1,"eyeLift":0,"eyeSpread":1},
                  "agent":"claude","instructions":"","freedom":"ask","sessionId":"33333333-3333-4333-8333-333333333333",
                  "notifications":true,"pinned":false,"createdAt":"2026-10-12T10:00:00.000Z",
                  "skills":[],"plugins":[],"connectors":false}]}
        """#
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(state.utf8).write(to: paths.stateFile)
        let store = try Store(paths: paths)
        XCTAssertEqual(store.projects.first?.plugins, ["figma"])
        XCTAssertEqual(store.projects.first?.codexPlugins, [])
        XCTAssertNil(try XCTUnwrap(store.bots.first).threadId)
    }
}
