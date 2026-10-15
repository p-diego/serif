import XCTest
@testable import SerifCore

/// The 12/10 spike's session (`codex-c3.jsonl`: the server's lines, sanitized, numbered as in `prove_codex.md`), lines
/// `range` fed to a normalizer and shown one line per output: U user (origin when not the terminal), A assistant message
/// (whole), T/R step started/result, Q card (tool, what, decisions), X card resolved, E/I/F turn ended/interrupted/failed,
/// L rate limited.
private func session(_ range: ClosedRange<Int>, sent: [(String, MessageOrigin)] = []) throws -> [String] {
    var n = CodexNormalizer()
    for (text, origin) in sent { n.expectChatMessage(text, origin: origin) }
    var out: [NormalizerOutput] = []
    for line in try fixture("codex-c3.jsonl").split(separator: "\n") {
        let v = try JSONValue.parse(Data(line.utf8))
        guard let number = v["n"]?.int, range.contains(number), let message = CodexMessage(try XCTUnwrap(v["msg"]).encoded()) else { continue }
        out += n.ingest(message)
    }
    return shown(out)
}

private func shown(_ outputs: [NormalizerOutput]) -> [String] {
    var texts: [String: String] = [:], lines: [String] = []
    for o in outputs {
        switch o {
        case .event(.userMessage(let t, _, let origin, _)): lines.append("U\(origin == .terminal ? "" : "(\(origin.rawValue))"): \(t)")
        case .event(.assistantText(let id, _, let d, _, _)):
            if texts[id] == nil { lines.append("A:\(id)") }
            texts[id, default: ""] += d
        case .event(.assistantTextReplaced(let id, let t)): texts[id] = t
        case .event(.toolStarted(_, let name, let input, _)):
            lines.append("T: \(name) \(input["command"]?.string ?? input["file_path"]?.string ?? input["query"]?.string ?? "")")
        case .event(.toolFinished(_, let ok, let output, _)):
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("R: \(ok ? "ok" : "ko")" + (text.isEmpty ? "" : " \(text)"))
        case .serverRequest(_, let tool, let input, let decisions, _, _):
            let what = input["command"]?.string ?? input["questions"]?.array?.first?["question"]?.string ?? ""
            lines.append("Q: \(tool) \(what) \((decisions ?? []).joined(separator: ","))")
        case .serverRequestResolved(let id): lines.append("X: \(id.compactText)")
        case .event(.turnEnded(_, let last)): lines.append("E: \(last ?? "")")
        case .event(.turnInterrupted): lines.append("I")
        case .event(.turnFailed(let reason)): lines.append("F: \(reason)")
        case .rateLimited: lines.append("L")
        default: break
        }
    }
    return lines.map { $0.hasPrefix("A:") ? "A: " + (texts[String($0.dropFirst(2))] ?? "") : $0 }
}

private func notification(_ method: String, _ params: JSONValue) -> CodexMessage { .notification(method: method, params: params) }

final class CodexNormalizerTests: XCTestCase {
    func testAMessageWithFilesIsShownAsYourOwnWords() {
        // Spec §4 of 0.7: Codex echoes the text item (the images carry no text); the chat keeps your words and the files.
        var n = CodexNormalizer()
        let sent = messageText("Look", attachments: ["allegati/2026-10-15/foto.png"])
        n.expectChatMessage(sent, shown: "Look", attachments: ["allegati/2026-10-15/foto.png"])
        let echo = notification("item/completed", ["threadId": "t", "turnId": "turn-1", "item": ["type": "userMessage", "id": "u-1",
                                                                                                "content": [["type": "text", "text": .string(sent)]]]])
        XCTAssertEqual(n.ingest(echo), [.event(.userMessage(text: "Look", promptId: "turn-1", origin: .chat, attachments: ["allegati/2026-10-15/foto.png"]))])
    }

    func testATurnFromTheChat() throws {
        let sent = "Ricorda la parola segreta: GIRASOLE. Ora: scrivi una breve frase, poi esegui il comando shell `echo ciao`, poi scrivi una breve frase finale."
        XCTAssertEqual(try session(32...65, sent: [(sent, .introduction)]), [
            "U(introduction): \(sent)",
            "A: Ecco una breve frase: oggi il cielo è sereno.",        // the commentary is the bot's message too (spec §4)
            "T: Bash echo ciao",                                       // as typed, not "/bin/zsh -lc 'echo ciao'"
            "R: ok ciao",
            "A: Ciao!",
            "E: Ciao!",
        ])
    }

    func testATurnTypedInTheTerminal() throws {
        XCTAssertEqual(try session(66...78), ["U: Quanto fa 2+2? Rispondi solo con il numero.", "A: 4", "E: 4"])
    }

    func testApprovalsWithTheDecisionsCodexOffers() throws {
        // Each command opens a card with the decisions it came with (the permanent rule left to the terminal); the server's
        // `serverRequest/resolved` closes it, whoever answered; a declined command fails its step (spec §4).
        XCTAssertEqual(Array(try session(101...189).dropFirst(2)), [
            "T: Bash touch a.txt", "Q: Bash touch a.txt accept,cancel", "X: 0", "R: ok",
            "T: Bash touch b.txt", "Q: Bash touch b.txt accept,cancel", "X: 1", "R: ok",
            "T: Bash touch c.txt", "Q: Bash touch c.txt accept,cancel", "X: 2", "R: ko Declined",
            "A: Sono riusciti `touch a.txt` e `touch b.txt`; `touch c.txt` è stato rifiutato.",
            "E: Sono riusciti `touch a.txt` e `touch b.txt`; `touch c.txt` è stato rifiutato.",
        ])
    }

    func testAQuestionIsACardAndThePlanIsLeftOut() throws {
        let lines = try session(192...266)
        XCTAssertTrue(lines.contains("Q: AskUserQuestion In che lingua vuoi il saluto in saluto.txt? "))
        XCTAssertTrue(lines.contains("X: 4"))
        XCTAssertEqual(lines.last, "E: ")
    }

    func testAMessageSentDuringATurnJoinsIt() throws {
        XCTAssertEqual(try session(267...294, sent: [("Nella risposta finale aggiungi anche la parola BANANA.", .chat)]), [
            "U: Esegui il comando shell `sleep 12` e poi rispondi: fatto.",
            "T: Bash sleep 12", "R: ok",
            "U(chat): Nella risposta finale aggiungi anche la parola BANANA.",
            "A: fatto. BANANA", "E: fatto. BANANA",
        ])
    }

    func testInterruptedTurnsFailuresAndStepsThatCloseLater() throws {
        XCTAssertEqual(try session(295...341), [
            "U: Esegui il comando shell `sleep 30` e poi rispondi: fatto.", "A: Eseguo `sleep 30`.", "T: Bash sleep 30", "I",
            "U: Esegui il comando shell `sleep 25` e poi rispondi: fatto.", "T: Bash sleep 25", "I",
            "U: ciao",
            "F: The 'modello-inesistente' model is not supported when using Codex with a ChatGPT account.",   // the API's message
            "R: ok", "R: ok",          // the two commands an interruption left running end after their turns (spec §3.3)
        ])
    }

    func testUsageLimit() {
        // Not met in the trials (free plan): the shape is the schema's (spec §3.3).
        var n = CodexNormalizer()
        let error: JSONValue = ["message": "You've hit your usage limit.", "codexErrorInfo": "usageLimitExceeded"]
        let out = n.ingest(notification("error", ["error": error, "willRetry": false])) +
            n.ingest(notification("turn/completed", ["turn": ["id": "t", "status": "failed", "error": error]]))
        XCTAssertEqual(shown(out), ["F: You've hit your usage limit.", "L"])
        let other = n.ingest(notification("turn/completed", ["turn": ["id": "t", "status": "failed", "error": ["message": "x", "codexErrorInfo": ["httpConnectionFailed": [:]]]]]))
        XCTAssertEqual(shown(other), ["F: x"])
    }

    func testRepliesStreamByWholeLines() {
        var n = CodexNormalizer()
        var out: [NormalizerOutput] = []
        for delta in ["Uno", " due\ntre", "\nqua", "ttro"] {
            out += n.ingest(notification("item/agentMessage/delta", ["itemId": "m", "turnId": "t", "delta": .string(delta)]))
        }
        out += n.ingest(notification("item/completed", ["turnId": "t", "item": ["type": "agentMessage", "id": "m", "text": "Uno due\ntre\nquattro"]]))
        XCTAssertEqual(out, [
            .event(.assistantText(messageId: "m", index: 0, delta: "Uno due\n", final: false, promptId: "t")),
            .event(.assistantText(messageId: "m", index: 1, delta: "tre\n", final: false, promptId: "t")),
            .event(.assistantText(messageId: "m", index: 2, delta: "quattro", final: true, promptId: "t")),
        ])
        // A final text that differs from what streamed replaces it.
        out = n.ingest(notification("item/agentMessage/delta", ["itemId": "m2", "delta": "Ci"]))
            + n.ingest(notification("item/completed", ["item": ["type": "agentMessage", "id": "m2", "text": "Ciao"]]))
        XCTAssertEqual(out.last, .event(.assistantTextReplaced(messageId: "m2", text: "Ciao")))
    }

    func testAReplyCutShortClosesWithItsTurn() {
        // Interrupted while writing: no item/completed comes, what streamed of the reply is still the bot's message.
        var n = CodexNormalizer()
        var out: [NormalizerOutput] = []
        for delta in ["Eseguo", " `sleep`"] {
            out += n.ingest(notification("item/agentMessage/delta", ["itemId": "m", "turnId": "t", "delta": .string(delta)]))
        }
        out += n.ingest(notification("turn/completed", ["turn": ["id": "t", "status": "interrupted"]]))
        XCTAssertEqual(out, [.event(.assistantText(messageId: "m", index: 0, delta: "Eseguo `sleep`", final: true, promptId: "t")),
                             .event(.turnInterrupted)])
        // A reply that completed adds nothing at the turn's end.
        _ = n.ingest(notification("item/agentMessage/delta", ["itemId": "m2", "turnId": "t2", "delta": "Ciao"]))
        _ = n.ingest(notification("item/completed", ["turnId": "t2", "item": ["type": "agentMessage", "id": "m2", "text": "Ciao"]]))
        XCTAssertEqual(n.ingest(notification("turn/completed", ["turn": ["id": "t2", "status": "completed"]])),
                       [.event(.turnEnded(promptId: "t2", lastMessage: "Ciao"))])
    }

    func testOtherStepsReadLikeClaudeCodesTools() {
        // fileChange, mcpToolCall and webSearch never came up in the trials: their shapes are the schema's.
        var n = CodexNormalizer()
        let change: JSONValue = ["type": "fileChange", "id": "f", "status": "completed",
                                 "changes": [["path": "/w/notes.md", "kind": ["type": "update"], "diff": "@@ -1 +1 @@\n-a\n+b"]]]
        let mcp: JSONValue = ["type": "mcpToolCall", "id": "m", "server": "figma", "tool": "get_file", "status": "failed",
                              "arguments": ["key": "k"], "error": ["message": "no access"]]
        let search: JSONValue = ["type": "webSearch", "id": "w", "query": "swift"]
        let out = [change, mcp, search].flatMap { n.ingest(notification("item/completed", ["turnId": "t", "item": $0])) }
        XCTAssertEqual(shown(out), ["T: Edit /w/notes.md", "R: ok /w/notes.md", "T: mcp__figma__get_file ", "R: ko no access",
                                    "T: WebSearch swift", "R: ok"])
        // A file change's card names the files of the step that started just before it (the request does not).
        _ = n.ingest(notification("item/started", ["turnId": "t", "item": ["type": "fileChange", "id": "f2", "status": "inProgress",
                                                                            "changes": [["path": "/w/a.md", "diff": "+x"]]]]))
        let card = n.ingest(.request(id: 9, method: "item/fileChange/requestApproval", params: ["itemId": "f2", "turnId": "t"]))
        XCTAssertEqual(card, [.serverRequest(id: 9, toolName: "Edit", input: ["file_path": "/w/a.md", "content": "+x"],
                                             decisions: ["accept", "acceptForSession", "decline", "cancel"], turnId: "t", itemId: "f2")])
    }

    func testUnknownMessagesAreLeftToTheEngine() {
        // Review Focus 2: a newer Codex may send what 0.160 did not; nothing is made of it here.
        var n = CodexNormalizer()
        XCTAssertEqual(n.ingest(notification("thread/goal/updated", ["x": 1])), [])
        XCTAssertEqual(n.ingest(.request(id: 5, method: "item/tool/call", params: [:])), [])
        XCTAssertEqual(n.ingest(notification("item/completed", ["item": ["type": "somethingNew", "id": "s"]])), [])
    }

    func testACardAlwaysHasAnswers() {
        // Only the permanent rule offered: the card still gets accept, decline and cancel, which Codex takes even when not
        // listed (spike prova 3), so it can be answered and Esc works.
        let amendment: JSONValue = ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["touch"]]]
        XCTAssertEqual(CodexNormalizer.decisions(["availableDecisions": [amendment]]), ["accept", "decline", "cancel"])
        XCTAssertEqual(CodexNormalizer.decisions(["availableDecisions": ["accept", amendment]]), ["accept"])
    }
}
