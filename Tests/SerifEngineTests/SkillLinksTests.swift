import XCTest
@testable import SerifEngine

final class SkillLinksTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var bot: URL { root.appendingPathComponent("bot") }
    private var skillsDir: URL { bot.appendingPathComponent(".claude/skills") }

    override func setUp() { root = fm.temporaryDirectory.appendingPathComponent("serif-links-\(UUID().uuidString)") }
    override func tearDown() { try? fm.removeItem(at: root) }

    /// A skill folder (with its SKILL.md) under the test root; returns its path.
    private func skill(_ path: String) throws -> String {
        let dir = root.appendingPathComponent(path)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: x\n---\n".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir.path
    }

    private func link(_ name: String) -> String? { try? fm.destinationOfSymbolicLink(atPath: skillsDir.appendingPathComponent(name).path) }

    func testLinksChosenSkillsAndRemovesDroppedOnes() throws {
        let tidy = try skill("a/tidy"), docx = try skill("b/docx")
        XCTAssertEqual(linkSkills([tidy, docx], into: bot), [])
        XCTAssertEqual(link("tidy"), tidy)
        XCTAssertEqual(link("docx"), docx)
        XCTAssertEqual(linkSkills([docx], into: bot), [])
        XCTAssertNil(link("tidy"))
        XCTAssertEqual(link("docx"), docx)
        XCTAssertTrue(fm.fileExists(atPath: tidy + "/SKILL.md"))      // dropping the link never touches the skill
    }

    func testTheBotsOwnFolderIsNeverTouched() throws {
        let own = skillsDir.appendingPathComponent("tidy")              // a skill the bot wrote itself
        try fm.createDirectory(at: own, withIntermediateDirectories: true)
        try "mine".write(to: own.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let tidy = try skill("a/tidy")
        XCTAssertEqual(linkSkills([tidy], into: bot).count, 1)          // left out, and said so
        XCTAssertEqual(try String(contentsOf: own.appendingPathComponent("SKILL.md"), encoding: .utf8), "mine")
        XCTAssertEqual(linkSkills([], into: bot), [])
        XCTAssertTrue(fm.fileExists(atPath: own.appendingPathComponent("SKILL.md").path))
    }

    func testMissingSkillAndSameNameAreLeftOut() throws {
        let tidy = try skill("a/tidy"), twin = try skill("b/tidy"), gone = try skill("c/gone")
        XCTAssertEqual(linkSkills([gone], into: bot), [])
        try fm.removeItem(atPath: gone)                                 // the skill's folder disappears later
        XCTAssertEqual(linkSkills([tidy, twin, gone], into: bot).count, 2)
        XCTAssertEqual(link("tidy"), tidy)                              // first wins
        XCTAssertNil(link("gone"))                                      // its dangling link is gone too
    }

    /// A `.claude` or `.claude/skills` that is a link leads outside Serif (e.g. to the user's own skills): never edited.
    func testLinkedClaudeFoldersAreNeverFollowed() throws {
        let userSkills = root.appendingPathComponent("user-skills")
        let tidy = try skill("a/tidy")
        try fm.createDirectory(at: userSkills, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: userSkills.appendingPathComponent("tidy").path, withDestinationPath: tidy)
        try fm.createDirectory(at: bot.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: skillsDir, withDestinationURL: userSkills)
        XCTAssertEqual(linkSkills([], into: bot).count, 1)
        XCTAssertEqual(linkSkills([try skill("b/docx")], into: bot).count, 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: userSkills.path), ["tidy"])     // nothing removed, nothing added

        let userClaude = root.appendingPathComponent("user-claude")
        try fm.createDirectory(at: userClaude.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: userClaude.appendingPathComponent("skills/tidy").path, withDestinationPath: tidy)
        try fm.removeItem(at: bot.appendingPathComponent(".claude"))
        try fm.createSymbolicLink(at: bot.appendingPathComponent(".claude"), withDestinationURL: userClaude)
        XCTAssertEqual(linkSkills([], into: bot).count, 1)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: userClaude.appendingPathComponent("skills/tidy").path), tidy)
    }

    func testNoSkillsCreatesNothing() {
        XCTAssertEqual(linkSkills([], into: bot), [])
        XCTAssertFalse(fm.fileExists(atPath: skillsDir.path))
    }

    func testCodexSkillsGoUnderAgents() throws {
        let tidy = try skill("a/tidy")
        XCTAssertEqual(linkSkills([tidy], into: bot, under: ".agents/skills"), [])
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: bot.appendingPathComponent(".agents/skills/tidy").path), tidy)
        XCTAssertFalse(fm.fileExists(atPath: skillsDir.path))                       // nothing under .claude
        // A linked `.agents` leads outside Serif: never followed.
        let other = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let bot2 = root.appendingPathComponent("bot2")
        try fm.createDirectory(at: bot2, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: bot2.appendingPathComponent(".agents").path, withDestinationPath: other.path)
        XCTAssertEqual(linkSkills([tidy], into: bot2, under: ".agents/skills").count, 1)
        XCTAssertFalse(fm.fileExists(atPath: other.appendingPathComponent("skills").path))
    }
}
