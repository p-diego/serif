import XCTest
@testable import SerifCore

final class HistoryTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_792_000_000)
    private let face = BotFace(shape: .allCases[0], body: 0x6BC4A6, eyes: 0x14141A)
    private let botId = UUID()
    private var bot: Bot { Bot(id: botId, projectId: UUID(), name: "Cody", face: face, model: "sonnet", instructions: "Help.", skills: ["/s/a"]) }

    func testChangesAreFoundFieldByField() {
        // Spec §5: one line per field that changed, in the sheet's order; nothing for a bot saved as it was.
        var new = bot
        XCTAssertEqual(botChanges(from: bot, to: new, by: .user, at: at), [])
        new.name = "Cody2"; new.instructions = "Lead."; new.model = nil; new.skills = []; new.connectors = true
        new.pinned = true; new.sessionId = UUID()                            // not history (spec §5)
        let changes = botChanges(from: bot, to: new, by: .bot(id: bot.id, name: "Ada"), at: at)
        XCTAssertEqual(changes.map(\.field), [.name, .instructions, .model, .skills, .connectors])
        XCTAssertEqual(changes[0], BotChange(at: at, by: .bot(id: bot.id, name: "Ada"), field: .name, old: "Cody", new: "Cody2"))
        XCTAssertEqual(changes[2].old, "sonnet"); XCTAssertEqual(changes[2].new, .null)
        XCTAssertEqual(changes[3].old, ["/s/a"]); XCTAssertEqual(changes[3].new, [])
        XCTAssertEqual(changes[4].new, true)
        var other = bot
        (other.face, other.freedom, other.agent, other.notifications, other.plugins) = (BotFace(shape: .allCases[1], body: 1, eyes: 2), .auto, .codex, false, ["p"])
        XCTAssertEqual(botChanges(from: bot, to: other, by: .user, at: at).map(\.field), [.face, .freedom, .plugins, .agent, .notifications])
        XCTAssertEqual(fieldValue(other, .face)["body"], 1)
    }

    func testTheLineAsWritten() throws {
        // `{at, by: user | bot(id, name), field, old, new}` (spec §5), readable by hand.
        let change = BotChange(at: at, by: .user, field: .model, old: .null, new: "opus")
        let json = String(decoding: try protocolEncoder().encode(change), as: UTF8.self)
        XCTAssertTrue(json.contains(#""by":{"user":{}}"#), json)
        XCTAssertTrue(json.contains(#""field":"model""#) && json.contains(#""old":null"#) && json.contains(#""new":"opus""#), json)
        XCTAssertEqual(try protocolDecoder().decode(BotChange.self, from: Data(json.utf8)), change)
        let byBot = try protocolEncoder().encode(BotChange(at: at, by: .bot(id: bot.id, name: "Ada"), field: .name, old: "a", new: "b"))
        XCTAssertTrue(String(decoding: byBot, as: UTF8.self).contains(#""by":{"bot":{"#))
        // A field this version does not know (written by a later one) does not decode: the store skips the line.
        XCTAssertThrowsError(try protocolDecoder().decode(BotChange.self, from: Data(json.replacingOccurrences(of: "model", with: "pinned").utf8)))
    }

    func testALiteralLineDecodes() throws {
        // The on-disk names (`at, by, field, old, new`) are pinned against literal lines, not only a round trip.
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let user = #"{"at":"2026-10-15T10:00:00.000Z","by":{"user":{}},"field":"model","old":null,"new":"opus"}"#
        let byBot = #"{"at":"2026-10-15T10:00:00.000Z","by":{"bot":{"id":"\#(id)","name":"Ada"}},"field":"name","old":"a","new":"b"}"#
        let u = try protocolDecoder().decode(BotChange.self, from: Data(user.utf8))
        XCTAssertEqual(u.by, .user); XCTAssertEqual(u.field, .model); XCTAssertEqual(u.old, .null); XCTAssertEqual(u.new, "opus")
        let b = try protocolDecoder().decode(BotChange.self, from: Data(byBot.utf8))
        XCTAssertEqual(b.by, .bot(id: id, name: "Ada")); XCTAssertEqual(b.field, .name)
        XCTAssertEqual(b.old, "a"); XCTAssertEqual(b.new, "b")
    }

    func testRestorePutsTheOldValueBack() throws {
        // Spec §5: every field goes back; a value that does not fit the field is refused, never a crash.
        var new = bot
        new.name = "Cody2"; new.model = nil; new.face = BotFace(shape: .allCases[1], body: 1, eyes: 2); new.freedom = .auto
        new.agent = .codex; new.skills = []; new.connectors = true; new.notifications = false; new.instructions = ""; new.plugins = ["p"]
        for change in botChanges(from: bot, to: new, by: .user, at: at) {
            let restored = try XCTUnwrap(restoring(change, into: new), change.field.rawValue)
            XCTAssertEqual(fieldValue(restored, change.field), fieldValue(bot, change.field), change.field.rawValue)
        }
        XCTAssertNil(restoring(BotChange(at: at, by: .user, field: .freedom, old: "wild", new: "ask"), into: bot))
        XCTAssertNil(restoring(BotChange(at: at, by: .user, field: .face, old: "round", new: .null), into: bot))
        XCTAssertNil(restoring(BotChange(at: at, by: .user, field: .model, old: 3, new: .null), into: bot))
    }
}
