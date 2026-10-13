import XCTest
@testable import SerifCore

final class FormsTests: XCTestCase {
    func testValidation() {
        XCTAssertFalse(canCreateProject(name: "  \n"))
        XCTAssertTrue(canCreateProject(name: " Site "))
        XCTAssertFalse(canCreateBot(name: "Ada", projectId: nil))
        XCTAssertFalse(canCreateBot(name: " ", projectId: UUID()))
        XCTAssertTrue(canCreateBot(name: "Ada", projectId: UUID()))
    }

    func testModelMapping() {
        XCTAssertEqual(BotModel.allCases.map(\.value), [nil, "opus", "sonnet", "haiku"])
        XCTAssertEqual(BotModel(value: nil), .standard)
        XCTAssertEqual(BotModel(value: "sonnet"), .sonnet)
        XCTAssertEqual(BotModel(value: "claude-x"), .standard)   // unknown ids fall back to the default
    }

    func testDefaultProject() {
        let a = Project(name: "A"), b = Project(name: "B")
        XCTAssertEqual(defaultProjectId(projects: [a, b], selectedBotProject: b.id), b.id)
        XCTAssertEqual(defaultProjectId(projects: [a, b], selectedBotProject: nil), a.id)
        XCTAssertEqual(defaultProjectId(projects: [a, b], selectedBotProject: UUID()), a.id)
        XCTAssertNil(defaultProjectId(projects: [], selectedBotProject: nil))
    }

    func testEmptyStateFacesAreStable() {
        XCTAssertEqual(emptyStateFaces(count: 8), emptyStateFaces(count: 8))
        XCTAssertEqual(emptyStateFaces(count: 8).count, 8)
    }

    func testApplyingEditsKeepsLiveFields() {
        let face = BotFace(shape: .ball, body: 0xE8483F, eyes: 0xF5F7FC)
        var live = Bot(projectId: UUID(), name: "Old", face: face)
        live.pinned = true; live.archivedAt = Date(timeIntervalSince1970: 5)
        let edits = BotEdits(name: "New", face: face, model: "opus", instructions: "x", freedom: .auto, notifications: false,
                             skills: ["/s/tidy"], plugins: ["superpowers@official"], connectors: true)
        let out = live.applying(edits)
        XCTAssertEqual([out.name, out.model, out.instructions], ["New", "opus", "x"])
        XCTAssertEqual(out.freedom, .auto)
        XCTAssertFalse(out.notifications)
        XCTAssertEqual(out.skills, ["/s/tidy"])
        XCTAssertEqual(out.plugins, ["superpowers@official"])
        XCTAssertTrue(out.connectors)
        XCTAssertTrue(out.pinned)                      // changed meanwhile: kept
        XCTAssertEqual(out.sessionId, live.sessionId)
        XCTAssertEqual(out.archivedAt, live.archivedAt)
    }

    func testTemplateSuggestionsSkipWhatIsMissing() {
        var catalog = ClaudeCatalog()
        catalog.skills = [CatalogItem(id: "/s/docx", name: "docx", description: "", path: "/s/docx"),
                          CatalogItem(id: "/s/pdf", name: "pdf", description: "", path: "/s/pdf")]
        catalog.plugins = [CatalogItem(id: "superpowers@official", name: "superpowers", description: "", path: "/p/sp")]
        XCTAssertEqual(BotTemplate.writer.suggestions(skills: catalog.skills, plugins: catalog.plugins).skills, ["/s/docx", "/s/pdf"])   // no pptx on this Mac
        XCTAssertEqual(BotTemplate.developer.suggestions(skills: catalog.skills, plugins: catalog.plugins).plugins, ["superpowers@official"])
        XCTAssertEqual(BotTemplate.researcher.suggestions(skills: catalog.skills, plugins: catalog.plugins).skills, [])
        XCTAssertEqual(BotTemplate.reviewer.suggestions(skills: catalog.skills, plugins: catalog.plugins).skills, [])
        // The same names for a Codex bot, found among Codex's own lists (spec §7).
        let codex = [CatalogItem(id: "/s/docx", name: "docx", description: "", path: "/s/docx")]
        XCTAssertEqual(BotTemplate.writer.suggestions(skills: codex, plugins: []).skills, ["/s/docx"])
        XCTAssertEqual(BotTemplate.reviewer.freedom, .ask)
        XCTAssertEqual(BotTemplate.writer.freedom, .edits)
        XCTAssertEqual(Set(BotTemplate.allCases.map(\.face)).count, 4)
    }
}
