import Foundation
import XCTest
@testable import SerifCore

struct RecordedHook { let ts: Double; let event: String; let payload: JSONValue }

func recordedHooks(session prefix: String) throws -> [RecordedHook] {
    let url = Bundle.module.url(forResource: "Fixtures/hooks", withExtension: "jsonl")!
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
        let v = try JSONValue.parse(Data(line.utf8))
        guard let e = v["event"]?.string, !e.contains(":"),                // skip the probe's own ":hook-…" lines
              let p = v["payload"], p["session_id"]?.string?.hasPrefix(prefix) == true else { return nil }
        return RecordedHook(ts: v["ts"]!.double!, event: e, payload: p)
    }
}

/// Feed a recorded session and render a compact transcript: U/A/T/R/E lines.
func replay(_ hooks: [RecordedHook]) -> [String] {
    var n = ClaudeNormalizer(); var out: [NormalizerOutput] = []
    for h in hooks { out += n.ingest(h.payload, at: Date(timeIntervalSince1970: h.ts)) }
    out += n.flush(now: .distantFuture)
    var texts: [String: String] = [:]; var order: [String] = []; var lines: [String] = []
    for o in out {
        guard case .event(let e) = o else { continue }
        switch e {
        case .userMessage(let t, _, _, _): lines.append("U: \(t)")
        case .assistantText(let id, _, let d, _, _):
            if texts[id] == nil { order.append(id); lines.append("A:\(id)") }
            texts[id, default: ""] += d
        case .assistantTextReplaced(let id, let t): texts[id] = t
        case .toolStarted(_, let name, let input, _): lines.append("T: \(name) \(input["command"]?.string ?? "")")
        case .toolFinished(_, let ok, let output, _): lines.append("R: \(ok ? "ok" : "ko") \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        case .turnEnded: lines.append("E")
        default: break
        }
    }
    return lines.map { $0.hasPrefix("A:") ? "A: " + (texts[String($0.dropFirst(2))] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : $0 }
}

func fixture(_ name: String) throws -> String {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))
    // Some captures contain stray non-UTF-8 bytes: decode leniently.
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

extension Array where Element: Equatable {
    func containsSequence(_ s: [Element]) -> Bool {
        guard !s.isEmpty, count >= s.count else { return false }
        return (0...(count - s.count)).contains { Array(self[$0..<($0 + s.count)]) == s }
    }
}
