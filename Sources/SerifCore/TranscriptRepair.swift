import Foundation

public struct TranscriptText: Equatable, Sendable {
    public let afterToolUseId: String?
    public let text: String
    public init(afterToolUseId: String?, text: String) { self.afterToolUseId = afterToolUseId; self.text = text }
}

/// Assistant text blocks of the turn started by `prompt`, in order, each tagged with the id of the tool_use that
/// precedes it in the same turn (nil = before any tool). Returns nil if nothing parses or the prompt isn't found.
public func transcriptTexts(transcriptJSONL: String, prompt: String) -> [TranscriptText]? {
    let wanted = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    var parsed = false, inTurn = false, found = false
    var lastTool: String?
    var out: [TranscriptText] = []
    for line in transcriptJSONL.split(separator: "\n") {
        guard let v = try? JSONValue.parse(Data(line.utf8)), let type = v["type"]?.string else { continue }
        parsed = true
        if v["isSidechain"]?.bool == true { continue }              // subagent traffic
        let content = v["message"]?["content"]
        if type == "user", let text = content?.string {
            // The last matching prompt wins (the turn that just finished); restart on every match.
            inTurn = text.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
            if inTurn { found = true; lastTool = nil; out = [] }
        } else if type == "assistant", inTurn, let blocks = content?.array {
            for b in blocks {
                switch b["type"]?.string {
                case "tool_use": lastTool = b["id"]?.string
                case "text": if let t = b["text"]?.string { out.append(TranscriptText(afterToolUseId: lastTool, text: t)) }
                default: break
                }
            }
        }
    }
    return parsed && found ? out : nil
}

/// Replacements (messageId → full text) for messages whose streamed text differs from the transcript,
/// computed per gap between tools and only where a gap has as many messages as the transcript has texts.
public func repairs(turn: [ChatEvent], transcript: [TranscriptText]) -> [String: String] {
    var gapIds: [String?: [String]] = [:]
    var streamed: [String: String] = [:]
    var gap: String?
    for e in turn {
        switch e {
        case .toolStarted(let id, _, _, _): gap = id
        case .assistantText(let id, _, let delta, _, _):
            if streamed[id] == nil { gapIds[gap, default: []].append(id) }
            streamed[id, default: ""] += delta
        default: break
        }
    }
    var result: [String: String] = [:]
    for (key, ids) in gapIds {
        let texts = transcript.filter { $0.afterToolUseId == key }.map(\.text)
        guard texts.count == ids.count else { continue }
        for (id, text) in zip(ids, texts) where streamed[id] != text { result[id] = text }
    }
    return result
}
