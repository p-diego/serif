import XCTest
@testable import SerifCore

final class ModelsTests: XCTestCase {
    func testFreedomMapsToClaudeModes() {
        XCTAssertEqual(Freedom.ask.claudePermissionMode, "manual")
        XCTAssertEqual(Freedom.edits.claudePermissionMode, "acceptEdits")
        XCTAssertEqual(Freedom.auto.claudePermissionMode, "auto")
    }
    func testPathsUseSerifHome() {
        let p = SerifPaths.standard(environment: ["SERIF_HOME": "/tmp/serif-x"])
        XCTAssertEqual(p.engineSocket.path, "/tmp/serif-x/serifd.sock")
        let id = UUID()
        XCTAssertEqual(p.bot(id).workspace.path, "/tmp/serif-x/bots/\(id.uuidString)/workspace")
        XCTAssertEqual(p.shared(id).path, "/tmp/serif-x/projects/\(id.uuidString)/shared")
    }
    func testSocketPathsFitUnixLimit() {
        let p = SerifPaths.standard(environment: [:])
        XCTAssertLessThan(p.engineSocket.path.utf8.count, 104)
        XCTAssertLessThan(p.hookSocket.path.utf8.count, 104)
    }
    func testBotCodableRoundTrip() throws {
        let bot = Bot(projectId: UUID(), name: "Chief", face: BotFace(shape: .allCases[0], body: 0x6BC4A6, eyes: 0x14141A))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(Bot.self, from: enc.encode(bot)).name, "Chief")
    }
}
