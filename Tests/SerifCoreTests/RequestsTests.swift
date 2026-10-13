import XCTest
@testable import SerifCore

final class RequestsTests: XCTestCase {
    private func request(_ kind: WaitKind, input: JSONValue = .object([:]), suggestions: JSONValue? = nil) -> PendingRequest {
        PendingRequest(botId: UUID(), kind: kind, toolName: "T", input: input,
                       toolUseId: "tu", promptId: nil, suggestions: suggestions)
    }

    private func decision(_ outcome: HookOutcome) throws -> JSONValue {
        guard case .reply(let json) = outcome else { XCTFail("expected reply, got \(outcome)"); return .null }
        let out = try JSONValue.parse(Data(json.utf8))
        XCTAssertEqual(out["hookSpecificOutput"]?["hookEventName"]?.string, "PermissionRequest")
        return out["hookSpecificOutput"]?["decision"] ?? .null
    }

    func testAllowReplies() throws {
        let d = try decision(hookOutcome(for: .allow, request: request(.permission)))
        XCTAssertEqual(d["behavior"]?.string, "allow")
        XCTAssertNil(d["updatedPermissions"])
    }

    func testAllowSessionCopiesSuggestionsWithSessionDestination() throws {
        let suggestions: JSONValue = .array([
            .object(["type": .string("addRules"), "destination": .string("localSettings")]),
            .object(["type": .string("setMode"), "destination": .string("projectSettings")]),
        ])
        let d = try decision(hookOutcome(for: .allowSession, request: request(.permission, suggestions: suggestions)))
        XCTAssertEqual(d["behavior"]?.string, "allow")
        let perms = d["updatedPermissions"]?.array
        XCTAssertEqual(perms?.count, 2)
        XCTAssertEqual(perms?[0]["destination"]?.string, "session")
        XCTAssertEqual(perms?[1]["destination"]?.string, "session")
        XCTAssertEqual(perms?[0]["type"]?.string, "addRules")
    }

    func testAllowSessionWithoutSuggestionsIsPlainAllow() throws {
        let d = try decision(hookOutcome(for: .allowSession, request: request(.permission)))
        XCTAssertEqual(d["behavior"]?.string, "allow")
        XCTAssertNil(d["updatedPermissions"])
    }

    func testDenyUsesMessageOrDefault() throws {
        let withMsg = try decision(hookOutcome(for: .deny(message: "no rm"), request: request(.permission)))
        XCTAssertEqual(withMsg["behavior"]?.string, "deny")
        XCTAssertEqual(withMsg["message"]?.string, "no rm")
        let plain = try decision(hookOutcome(for: .deny(message: nil), request: request(.permission)))
        XCTAssertEqual(plain["message"]?.string, "The user denied this action.")
    }

    func testAnswersAddsAnswersToOriginalInput() throws {
        let input: JSONValue = .object([
            "questions": .array([.object(["question": .string("Che colore preferisci?")])]),
        ])
        let answers: [String: [String]] = [
            "Che colore preferisci?": ["rosso"],
            "Quali frutti?": ["mela", "pera"],
        ]
        let d = try decision(hookOutcome(for: .answers(answers), request: request(.question, input: input)))
        XCTAssertEqual(d["behavior"]?.string, "allow")
        let updated = d["updatedInput"]
        XCTAssertNotNil(updated?["questions"]?.array, "original tool_input fields must be kept")
        XCTAssertEqual(updated?["answers"]?["Che colore preferisci?"]?.string, "rosso")
        XCTAssertEqual(updated?["answers"]?["Quali frutti?"]?.string, "mela, pera")
    }

    func testDenyOnQuestionReplies() throws {
        let d = try decision(hookOutcome(for: .deny(message: "stop"), request: request(.question)))
        XCTAssertEqual(d["behavior"]?.string, "deny")
        XCTAssertEqual(d["message"]?.string, "stop")
    }

    func testApprovePlanTypesTwoInTerminal() {
        XCTAssertEqual(hookOutcome(for: .approvePlan, request: request(.plan)), .typeInTerminal("2"))
    }

    func testRejectPlanDeniesWithMessage() throws {
        let d = try decision(hookOutcome(for: .rejectPlan(message: "meglio di no"), request: request(.plan)))
        XCTAssertEqual(d["behavior"]?.string, "deny")
        XCTAssertEqual(d["message"]?.string, "meglio di no")
    }

    func testDenyOnPlanReplies() throws {
        let d = try decision(hookOutcome(for: .deny(message: nil), request: request(.plan)))
        XCTAssertEqual(d["behavior"]?.string, "deny")
    }

    func testAnswerOfWrongKindIsSilent() {
        XCTAssertEqual(hookOutcome(for: .answers(["q": ["a"]]), request: request(.permission)), .silent)
        XCTAssertEqual(hookOutcome(for: .allow, request: request(.question)), .silent)
        XCTAssertEqual(hookOutcome(for: .approvePlan, request: request(.permission)), .silent)
        XCTAssertEqual(hookOutcome(for: .allowSession, request: request(.plan)), .silent)
        XCTAssertEqual(hookOutcome(for: .rejectPlan(message: "x"), request: request(.question)), .silent)
    }
}

final class QuestionAnswerTests: XCTestCase {
    private func request(_ questions: [JSONValue]) -> PendingRequest {
        PendingRequest(botId: UUID(), kind: .question, toolName: "AskUserQuestion",
                       input: .object(["questions": .array(questions)]), toolUseId: nil, promptId: nil, suggestions: nil)
    }
    private func q(_ text: String, _ labels: [String], multi: Bool = false) -> JSONValue {
        .object(["question": .string(text), "multiSelect": .bool(multi),
                 "options": .array(labels.map { .object(["label": .string($0)]) })])
    }

    func testSingleMultiAndSeveralQuestions() {
        let specs = questionSpecs(request([q("Colore?", ["Rosso", "Verde", "Blu"]), q("Extra?", ["A", "B", "C"], multi: true)]))
        XCTAssertEqual(specs.count, 2)
        XCTAssertTrue(specs[1].multiSelect)
        XCTAssertEqual(questionAnswer(specs, chosen: [0: ["Verde"], 1: ["C", "A"]]),
                       .answers(["Colore?": ["Verde"], "Extra?": ["A", "C"]]))    // option order, not pick order
        XCTAssertEqual(questionAnswer(Array(specs.prefix(1)), chosen: [0: ["Blu"]]), .answers(["Colore?": ["Blu"]]))
    }
}
