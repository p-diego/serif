import XCTest
@testable import SerifCore

final class TranscriptRepairTests: XCTestCase {
    func testTranscriptRepairFillsMissingLines() throws {
        let t = try XCTUnwrap(transcriptTexts(transcriptJSONL: try fixture("transcript-s1.jsonl"),
                                              prompt: "Scrivi i numeri da 1 a 150, uno per riga, senza altro testo."))
        XCTAssertEqual(t.count, 1); XCTAssertTrue(t[0].text.contains("\n35\n"))
        let turn: [ChatEvent] = [.assistantText(messageId: "m", index: 0, delta: "1\n2\n", final: false, promptId: "p")]
        XCTAssertEqual(repairs(turn: turn, transcript: t)["m"], t[0].text)
    }

    func testTranscriptRepairSkipsWhenGapsDontMatch() {
        let t = [TranscriptText(afterToolUseId: nil, text: "a"), TranscriptText(afterToolUseId: nil, text: "b")]
        let turn: [ChatEvent] = [.assistantText(messageId: "m", index: 0, delta: "x", final: false, promptId: "p")]
        XCTAssertEqual(repairs(turn: turn, transcript: t), [:])
    }

    func testGapsAfterToolsAndUnchangedTextIgnored() {
        let t = [TranscriptText(afterToolUseId: nil, text: "one"), TranscriptText(afterToolUseId: "t1", text: "two!")]
        let turn: [ChatEvent] = [
            .assistantText(messageId: "a", index: 0, delta: "one", final: true, promptId: "p"),
            .toolStarted(toolUseId: "t1", name: "Bash", input: .null, promptId: "p"),
            .assistantText(messageId: "b", index: 0, delta: "two", final: true, promptId: "p")]
        XCTAssertEqual(repairs(turn: turn, transcript: t), ["b": "two!"])
    }

    func testMalformedLinesAndMissingPrompt() {
        let jsonl = "garbage\n{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}\n{\"type\":\"x\"}\n"
            + "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"yo\"}]}}\n"
        XCTAssertEqual(transcriptTexts(transcriptJSONL: jsonl, prompt: " hi ")?.map(\.text), ["yo"])
        XCTAssertNil(transcriptTexts(transcriptJSONL: jsonl, prompt: "nope"))
    }
}

extension TranscriptRepairTests {
    private func user(_ t: String) -> String { "{\"type\":\"user\",\"message\":{\"content\":\"\(t)\"}}\n" }
    private func asst(_ t: String, side: Bool = false) -> String {
        "{\"type\":\"assistant\",\"isSidechain\":\(side),\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"\(t)\"}]}}\n"
    }

    func testRepeatedPromptUsesLastTurn() {
        let jsonl = user("ok") + asst("old") + user("other") + asst("mid") + user("ok") + asst("new")
        XCTAssertEqual(transcriptTexts(transcriptJSONL: jsonl, prompt: "ok")?.map(\.text), ["new"])
    }

    func testSidechainLinesAreSkipped() {
        let jsonl = user("hi") + asst("sub", side: true) + asst("main")
        XCTAssertEqual(transcriptTexts(transcriptJSONL: jsonl, prompt: "hi")?.map(\.text), ["main"])
    }
}
