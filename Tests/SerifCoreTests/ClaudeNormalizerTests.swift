import XCTest
@testable import SerifCore

final class ClaudeNormalizerTests: XCTestCase {
    func testFirstTurnOrdersTextBeforeTool() throws {
        let lines = replay(try recordedHooks(session: "542bb6ac"))
        XCTAssertEqual(Array(lines.prefix(6)).map { String($0.prefix(14)) }, [
            "U: Scrivi una ", "A: Il gatto do", "T: Bash echo c", "R: ok ciao", "A: Il cane cor", "E"])
    }
    func testQueuedMessageJoinsTheRunningTurn() throws {
        let lines = replay(try recordedHooks(session: "542bb6ac"))
        let second = Array(lines.drop(while: { !$0.contains("tre chiamate") }))
        XCTAssertTrue(second[0].hasPrefix("U: Esegui con Bash"))
        XCTAssertTrue(second.contains("U: Quando hai finito, dimmi quanto fa 2+2."))
        XCTAssertEqual(second.filter { $0 == "E" }.count >= 1, true)
        let idxDue = try XCTUnwrap(second.firstIndex { $0.hasPrefix("T: Bash echo due") })
        XCTAssertTrue(second[idxDue - 1].hasPrefix("A: Il primo comando"))   // text before its tool
    }
    func testLongMessageIsRepairedByStop() throws {
        let lines = replay(try recordedHooks(session: "542bb6ac"))
        let numbers = try XCTUnwrap(lines.first { $0.hasPrefix("A: 1\n2\n3") })
        XCTAssertTrue(numbers.contains("\n35\n"))      // missing from MessageDisplay, present in Stop
        XCTAssertTrue(numbers.hasSuffix("150"))
    }
    func testResumedSessionAddsTheResumedNote() {
        var n = ClaudeNormalizer()
        func start(_ source: String) -> [NormalizerOutput] {
            n.ingest(.object(["hook_event_name": .string("SessionStart"), "source": .string(source)]), at: Date())
        }
        XCTAssertEqual(start("startup"), [.sessionStarted(source: "startup")])
        XCTAssertEqual(start("resume"), [.sessionStarted(source: "resume"), .event(.system(.resumed))])
    }
    func testOriginChatVersusTerminal() throws {
        var n = ClaudeNormalizer()
        n.expectChatMessage("ciao")
        let p1: JSONValue = .object(["hook_event_name": .string("UserPromptSubmit"), "prompt": .string("ciao "), "prompt_id": .string("p")])
        let p2: JSONValue = .object(["hook_event_name": .string("UserPromptSubmit"), "prompt": .string("altro"), "prompt_id": .string("p")])
        XCTAssertEqual(n.ingest(p1, at: Date()), [.event(.userMessage(text: "ciao ", promptId: "p", origin: .chat))])
        XCTAssertEqual(n.ingest(p2, at: Date()), [.event(.userMessage(text: "altro", promptId: "p", origin: .terminal))])
    }
    func testPermissionRequestBindsToStartedTool() throws {
        var n = ClaudeNormalizer(); let t = Date()
        let input: JSONValue = .object(["command": .string("touch a.txt")])
        _ = n.ingest(.object(["hook_event_name": .string("PreToolUse"), "tool_name": .string("Bash"), "tool_input": input,
                              "tool_use_id": .string("toolu_1"), "prompt_id": .string("p")]), at: t)
        let out = n.ingest(.object(["hook_event_name": .string("PermissionRequest"), "tool_name": .string("Bash"),
                                    "tool_input": input, "prompt_id": .string("p")]), at: t.addingTimeInterval(0.01))
        XCTAssertTrue(out.contains(.permissionRequest(toolName: "Bash", input: input, suggestions: nil, promptId: "p", toolUseId: "toolu_1")))
        // rule 5: the held PreToolUse was released before the permission request
        XCTAssertEqual(out.first, .event(.toolStarted(toolUseId: "toolu_1", name: "Bash", input: input, promptId: "p")))
    }
    func testDeniedToolOnlyInBatch() throws {
        // probe s2(c): a denied tool has no PostToolUse; it must still appear as a failed step
        var n = ClaudeNormalizer(); let t = Date()
        let out = n.ingest(.object(["hook_event_name": .string("PostToolBatch"), "prompt_id": .string("p"), "tool_calls": .array([
            .object(["tool_name": .string("Bash"), "tool_input": .object(["command": .string("touch c.txt")]),
                     "tool_use_id": .string("toolu_9"), "tool_response": .string("<tool_use_error>Blocked</tool_use_error>")])])]), at: t)
        XCTAssertEqual(out.compactMap { if case .event(.toolFinished(let id, let ok, _, _)) = $0 { return "\(id) \(ok)" } else { return nil } }, ["toolu_9 false"])
    }
    func testHeldStopReleasedByFlushDeadline() {
        var n = ClaudeNormalizer(); let t = Date()
        let out = n.ingest(.object(["hook_event_name": .string("Stop"), "prompt_id": .string("p"), "last_assistant_message": .string("ok")]), at: t)
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(n.nextDeadline, t.addingTimeInterval(0.3))
        XCTAssertTrue(n.flush(now: t.addingTimeInterval(0.29)).isEmpty)
        XCTAssertFalse(n.flush(now: t.addingTimeInterval(0.31)).isEmpty)
    }

    // MARK: - Review fixes

    private func ev(_ name: String, _ f: [String: JSONValue] = [:]) -> JSONValue {
        var o = f; o["hook_event_name"] = .string(name); return .object(o)
    }
    private func str(_ s: String) -> JSONValue { .string(s) }

    func testSamePromptEventQueuesBehindHeldToolAndTextJumpsAhead() {
        var n = ClaudeNormalizer(); let t = Date()
        let input: JSONValue = .object(["command": str("echo a")])
        XCTAssertTrue(n.ingest(ev("PreToolUse", ["tool_name": str("Bash"), "tool_input": input, "tool_use_id": str("u1"), "prompt_id": str("p")]), at: t).isEmpty)
        XCTAssertTrue(n.ingest(ev("PostToolUse", ["tool_name": str("Bash"), "tool_use_id": str("u1"), "prompt_id": str("p"), "tool_response": str("a")]), at: t.addingTimeInterval(0.022)).isEmpty)
        let text = n.ingest(ev("MessageDisplay", ["message_id": str("m"), "index": .number(0), "delta": str("hi"), "final": .bool(true), "prompt_id": str("p")]), at: t.addingTimeInterval(0.025))
        XCTAssertEqual(text, [.event(.assistantText(messageId: "m", index: 0, delta: "hi", final: true, promptId: "p"))])
        XCTAssertEqual(n.nextDeadline, t.addingTimeInterval(0.3))
        XCTAssertEqual(n.flush(now: t.addingTimeInterval(0.4)), [
            .event(.toolStarted(toolUseId: "u1", name: "Bash", input: input, promptId: "p")),
            .event(.toolFinished(toolUseId: "u1", ok: true, output: "a", durationMs: nil)),
            .toolResolved(toolUseId: "u1")])
    }

    func testOtherPromptReleasesHeldQueue() {
        var n = ClaudeNormalizer(); let t = Date()
        _ = n.ingest(ev("PreToolUse", ["tool_name": str("Bash"), "tool_use_id": str("u1"), "prompt_id": str("p")]), at: t)
        let out = n.ingest(ev("UserPromptSubmit", ["prompt": str("x"), "prompt_id": str("q")]), at: t.addingTimeInterval(0.01))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.last, .event(.userMessage(text: "x", promptId: "q", origin: .terminal)))
    }

    func testBatchEntryWithoutResultIsAlwaysFailure() {
        var n = ClaudeNormalizer(); let t = Date()
        _ = n.ingest(ev("PostToolUse", ["tool_use_id": str("done"), "prompt_id": str("p"), "tool_response": str("ok")]), at: t)
        let out = n.ingest(ev("PostToolBatch", ["prompt_id": str("p"), "tool_calls": .array([
            .object(["tool_name": str("Bash"), "tool_use_id": str("done"), "tool_response": str("ok")]),
            .object(["tool_name": str("Bash"), "tool_use_id": str("den"), "tool_response": str("The user doesn't want to proceed")])])]), at: t)
        XCTAssertEqual(out.compactMap { if case .event(.toolFinished(let id, let ok, _, _)) = $0 { return "\(id) \(ok)" } else { return nil } }, ["den false"])
    }

    private func stopOutputs(stored: String, last: String) -> [NormalizerOutput] {
        var n = ClaudeNormalizer(); let t = Date()
        _ = n.ingest(ev("MessageDisplay", ["message_id": str("m"), "index": .number(0), "delta": str(stored), "final": .bool(true), "prompt_id": str("p")]), at: t)
        _ = n.ingest(ev("Stop", ["prompt_id": str("p"), "last_assistant_message": str(last)]), at: t)
        return n.flush(now: t.addingTimeInterval(1))
    }
    func testStopRepairOnlyWhenLinesWereDropped() {
        XCTAssertEqual(stopOutputs(stored: "ok\n", last: "ok"), [.event(.turnEnded(promptId: "p", lastMessage: "ok"))])
        XCTAssertEqual(stopOutputs(stored: "alpha", last: "beta"), [.event(.turnEnded(promptId: "p", lastMessage: "beta"))])
        XCTAssertEqual(stopOutputs(stored: "1\n2\n5", last: "1\n2\n3\n4\n5"), [
            .event(.assistantTextReplaced(messageId: "m", text: "1\n2\n3\n4\n5")),
            .event(.turnEnded(promptId: "p", lastMessage: "1\n2\n3\n4\n5"))])
    }

    func testChatOriginSkipsPendingTextsThatNeverArrived() {
        var n = ClaudeNormalizer()
        n.expectChatMessage("first"); n.expectChatMessage("second")
        let out = n.ingest(ev("UserPromptSubmit", ["prompt": str("second"), "prompt_id": str("p")]), at: Date())
        XCTAssertEqual(out, [.event(.userMessage(text: "second", promptId: "p", origin: .chat))])
    }

    func testUnknownEventDoesNotReleaseHeldItems() {
        var n = ClaudeNormalizer(); let t = Date()
        _ = n.ingest(ev("Stop", ["prompt_id": str("p"), "last_assistant_message": str("ok")]), at: t)
        XCTAssertTrue(n.ingest(ev("SomethingNew", ["prompt_id": str("q")]), at: t).isEmpty)
        XCTAssertNotNil(n.nextDeadline)
    }

    func testFailureOutputIsErrorFieldOrFallback() {
        var n = ClaudeNormalizer(); let t = Date()
        let a = n.ingest(ev("PostToolUseFailure", ["tool_use_id": str("a"), "error": str("boom")]), at: t)
        let b = n.ingest(ev("PostToolUseFailure", ["tool_use_id": str("b"), "secret": str("x")]), at: t)
        XCTAssertEqual(a.first, .event(.toolFinished(toolUseId: "a", ok: false, output: "boom", durationMs: nil)))
        XCTAssertEqual(b.first, .event(.toolFinished(toolUseId: "b", ok: false, output: "Tool failed", durationMs: nil)))
    }

    func testRateLimitOnlyFromTheErrorField() {
        var n = ClaudeNormalizer(); let t = Date()
        let limited = n.ingest(ev("StopFailure", ["error": str("rate_limit"), "error_details": str("429")]), at: t)
        XCTAssertEqual(limited, [.event(.turnFailed(reason: "rate_limit")), .rateLimited])
        // "rate_limit" elsewhere in the payload (e.g. the reply text) is not a rate limit.
        let other = n.ingest(ev("StopFailure", ["error": str("server_error"), "last_assistant_message": str("about rate_limit")]), at: t)
        XCTAssertEqual(other, [.event(.turnFailed(reason: "server_error"))])
    }

    func testInterruptedClosesOpenToolsAfterReleasingHeld() {
        var n = ClaudeNormalizer(); let t = Date()
        _ = n.ingest(ev("UserPromptSubmit", ["prompt": str("go"), "prompt_id": str("p")]), at: t)
        _ = n.ingest(ev("PreToolUse", ["tool_name": str("Bash"), "tool_use_id": str("u1"), "prompt_id": str("p")]), at: t)
        _ = n.ingest(ev("Stop", ["prompt_id": str("p")]), at: t)
        XCTAssertEqual(n.interrupted(at: t), [
            .event(.toolStarted(toolUseId: "u1", name: "Bash", input: .null, promptId: "p")),
            .event(.turnEnded(promptId: "p", lastMessage: nil)),
            .event(.toolFinished(toolUseId: "u1", ok: false, output: "Interrupted", durationMs: nil)),
            .event(.turnInterrupted)])
        XCTAssertNil(n.nextDeadline)
    }

    func testIntroductionKeepsItsOrigin() {
        var n = ClaudeNormalizer()
        n.expectChatMessage("Introduce yourself.\n- briefly\n", origin: .introduction)
        n.expectChatMessage("hello")
        func submit(_ text: String, _ id: String) -> [NormalizerOutput] {
            n.ingest(.object(["hook_event_name": .string("UserPromptSubmit"), "prompt": .string(text), "prompt_id": .string(id)]),
                     at: Date())
        }
        // Claude Code may trim what was pasted: it is still Serif's introduction, not the user's message.
        XCTAssertEqual(submit("Introduce yourself.\n- briefly", "p0"),
                       [.event(.userMessage(text: "Introduce yourself.\n- briefly", promptId: "p0", origin: .introduction))])
        XCTAssertEqual(submit("hello", "p1"), [.event(.userMessage(text: "hello", promptId: "p1", origin: .chat))])
    }
}
