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
        let edits = BotEdits(name: "New", face: face, model: "opus", instructions: "x", freedom: .auto, notifications: false)
        let out = live.applying(edits)
        XCTAssertEqual([out.name, out.model, out.instructions], ["New", "opus", "x"])
        XCTAssertEqual(out.freedom, .auto)
        XCTAssertFalse(out.notifications)
        XCTAssertTrue(out.pinned)                      // changed meanwhile: kept
        XCTAssertEqual(out.sessionId, live.sessionId)
        XCTAssertEqual(out.archivedAt, live.archivedAt)
    }
}
