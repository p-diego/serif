import Foundation

public enum NormalizerOutput: Equatable, Sendable {
    case event(ChatEvent)
    case permissionRequest(toolName: String, input: JSONValue, suggestions: JSONValue?, promptId: String?, toolUseId: String?)
    case toolResolved(toolUseId: String)
    case sessionStarted(source: String?)
    case sessionEnded(reason: String?)
    case notification(type: String?)
    case rateLimited
    case transcriptPath(String)
    /// A Codex server's request for a card (approvals, questions), with the decisions it accepts; `id` is its JSON-RPC id.
    case serverRequest(id: JSONValue, toolName: String, input: JSONValue, decisions: [String]?, turnId: String?, itemId: String?)
    /// Some client (the bot's terminal, or Serif) answered the Codex request `id`.
    case serverRequestResolved(id: JSONValue)
}

/// Texts Serif sent, waiting for the agent to report them as user messages: a match takes the origin it was sent with,
/// anything else was typed in the terminal. Compared trimmed (Claude Code trims); earlier entries never arrived. A text
/// sent with files or headed by new instructions (spec §4, §6 of 0.7) is shown as your own words (`shown`).
struct SentMessages {
    private var pending: [(sent: String, shown: String?, origin: MessageOrigin, attachments: [String]?)] = []
    mutating func expect(_ sent: String, origin: MessageOrigin, shown: String? = nil, attachments: [String]? = nil) {
        pending.append((sent, shown, origin, attachments))
    }
    mutating func match(_ echo: String) -> (text: String, origin: MessageOrigin, attachments: [String]?) {
        let trimmed = echo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = pending.firstIndex(where: { $0.sent.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }) else {
            return (echo, .terminal, nil)
        }
        defer { pending.removeSubrange(0...i) }
        return (pending[i].shown ?? echo, pending[i].origin, pending[i].attachments)
    }
}

/// A tool's output as the chat keeps it: 20 000 characters at most.
func truncatedOutput(_ s: String) -> String { s.count > 20_000 ? String(s.prefix(20_000)) + "…" : s }

/// Turns Claude Code hook payloads into ordered chat events.
/// Hooks come from separate processes and can arrive a few ms out of order, so PreToolUse and Stop
/// are held for `holdWindow` to let the text written before them land first.
public struct ClaudeNormalizer {
    public static let holdWindow: TimeInterval = 0.3

    private struct Started { let id: String; let name: String; let input: JSONValue; let promptId: String? }
    private enum Item {
        case tool(Started)
        case stop(promptId: String?, last: String?)
        case followers([NormalizerOutput])      // outputs of a same-prompt event queued behind a held item
    }
    /// A follower inherits its leader's deadline so both are released together, in arrival order.
    private struct Held { let item: Item; let prompt: String?; let deadline: Date }

    private static let handled: Set<String> = [
        "PostToolUse", "PostToolUseFailure", "PostToolBatch", "UserPromptSubmit", "PermissionRequest", "Notification",
        "SessionStart", "SessionEnd", "StopFailure", "SubagentStart", "SubagentStop", "PreCompact"]

    private var started: [Started] = []
    private var finished: Set<String> = []
    private var held: [Held] = []
    private var texts: [String: String] = [:]               // accumulated MessageDisplay text per message id
    private var frozen: Set<String> = []                    // messages already replaced by Stop's full text
    private var lastMessage: [String: String] = [:]         // last assistant message id per prompt id
    private var sent = SentMessages()
    private var transcript: String?
    private var currentPrompt: String?

    public init() {}

    /// A text Serif is sending: its user message gets `origin`; `shown` (your own words) and `attachments` when the text
    /// the agent gets carries files or a notice (spec §4, §6 of 0.7).
    public mutating func expectChatMessage(_ text: String, origin: MessageOrigin = .chat, shown: String? = nil,
                                           attachments: [String]? = nil) {
        sent.expect(text, origin: origin, shown: shown, attachments: attachments)
    }
    public var nextDeadline: Date? { held.first?.deadline }

    public mutating func flush(now: Date) -> [NormalizerOutput] {
        var out: [NormalizerOutput] = []
        while let first = held.first, first.deadline <= now { held.removeFirst(); out += emit(first.item) }
        return out
    }

    public mutating func interrupted(at: Date) -> [NormalizerOutput] {
        var out = releaseAll()
        for s in started where !finished.contains(s.id) && s.promptId == currentPrompt {
            finished.insert(s.id)
            out.append(.event(.toolFinished(toolUseId: s.id, ok: false, output: "Interrupted", durationMs: nil)))
        }
        out.append(.event(.turnInterrupted))
        return out
    }

    public mutating func ingest(_ p: JSONValue, at: Date) -> [NormalizerOutput] {
        guard let name = p["hook_event_name"]?.string else { return [] }
        var out = flush(now: at)       // anything whose hold already expired goes first
        if let path = p["transcript_path"]?.string, path != transcript { transcript = path; out.append(.transcriptPath(path)) }
        let promptId = p["prompt_id"]?.string

        switch name {
        case "PreToolUse":
            guard let id = p["tool_use_id"]?.string else { return out }
            currentPrompt = promptId
            let s = Started(id: id, name: p["tool_name"]?.string ?? "", input: p["tool_input"] ?? .null, promptId: promptId)
            started.append(s)
            held.append(Held(item: .tool(s), prompt: promptId, deadline: at.addingTimeInterval(Self.holdWindow)))
        case "Stop":
            held.append(Held(item: .stop(promptId: promptId, last: p["last_assistant_message"]?.string), prompt: promptId,
                             deadline: at.addingTimeInterval(Self.holdWindow)))
        case "MessageDisplay":
            guard let mid = p["message_id"]?.string else { return out }
            if held.contains(where: { $0.prompt != promptId }) { out += releaseAll() }
            let delta = p["delta"]?.string ?? ""
            if !frozen.contains(mid) { texts[mid, default: ""] += delta }
            if let promptId { lastMessage[promptId] = mid }
            out.append(.event(.assistantText(messageId: mid, index: p["index"]?.int ?? 0, delta: delta,
                                             final: p["final"]?.bool ?? false, promptId: promptId)))
        default:
            guard Self.handled.contains(name) else { return out }
            if name == "UserPromptSubmit" { currentPrompt = promptId }
            // A permission request blocks Claude, so nothing more is coming: it releases instead of queueing.
            if name != "PermissionRequest", let leader = held.last, let promptId, held.allSatisfy({ $0.prompt == promptId }) {
                // Same prompt as what is held: queue behind it so arrival order is preserved.
                held.append(Held(item: .followers(handle(name, p, promptId)), prompt: promptId, deadline: leader.deadline))
            } else {
                out += releaseAll()
                out += handle(name, p, promptId)
            }
        }
        return out
    }

    // MARK: - Private

    private mutating func releaseAll() -> [NormalizerOutput] {
        let items = held; held = []
        return items.flatMap { emit($0.item) }
    }

    private mutating func emit(_ item: Item) -> [NormalizerOutput] {
        switch item {
        case .tool(let s):
            return [.event(.toolStarted(toolUseId: s.id, name: s.name, input: s.input, promptId: s.promptId))]
        case .followers(let outputs):
            return outputs
        case .stop(let promptId, let last):
            var out: [NormalizerOutput] = []
            if let last, let promptId, let mid = lastMessage[promptId], let stored = texts[mid],
               Self.chomp(stored) != Self.chomp(last),
               last.hasPrefix(stored.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "") {
                texts[mid] = last
                frozen.insert(mid)
                out.append(.event(.assistantTextReplaced(messageId: mid, text: last)))
            }
            out.append(.event(.turnEnded(promptId: promptId, lastMessage: last)))
            if let promptId { prune(promptId) }
            return out
        }
    }

    /// Forget a finished turn's bookkeeping.
    private mutating func prune(_ promptId: String) {
        if let mid = lastMessage.removeValue(forKey: promptId) { texts[mid] = nil; frozen.remove(mid) }
        let done = Set(started.filter { $0.promptId == promptId && finished.contains($0.id) }.map(\.id))
        started.removeAll { done.contains($0.id) }
        finished.subtract(done)
    }

    private static func chomp(_ s: String) -> String { s.hasSuffix("\n") ? String(s.dropLast()) : s }

    private static func output(of response: JSONValue?) -> String {
        guard let response else { return "" }
        if let s = response.string { return truncatedOutput(s) }
        if response.object != nil, let stdout = response["stdout"]?.string {
            let err = response["stderr"]?.string ?? ""
            return truncatedOutput(stdout + (err.isEmpty ? "" : "\n" + err))
        }
        // An MCP tool answers with content items: their text, as Codex's mcpToolCall shows it.
        if let items = response.array {
            let text = items.compactMap { $0["text"]?.string }
            if !text.isEmpty { return truncatedOutput(text.joined(separator: "\n")) }
        }
        return truncatedOutput(response.compactText)
    }

    private mutating func finish(_ id: String, ok: Bool, output: String, durationMs: Int?) -> [NormalizerOutput] {
        finished.insert(id)
        return [.event(.toolFinished(toolUseId: id, ok: ok, output: output, durationMs: durationMs)), .toolResolved(toolUseId: id)]
    }

    private mutating func handle(_ name: String, _ p: JSONValue, _ promptId: String?) -> [NormalizerOutput] {
        switch name {
        case "PostToolUse":
            guard let id = p["tool_use_id"]?.string else { return [] }
            return finish(id, ok: true, output: Self.output(of: p["tool_response"]), durationMs: p["duration_ms"]?.int)
        case "PostToolUseFailure":
            guard let id = p["tool_use_id"]?.string else { return [] }
            let text = p["error"].map { $0.string ?? $0.compactText } ?? "Tool failed"
            return finish(id, ok: false, output: truncatedOutput(text), durationMs: p["duration_ms"]?.int)
        case "PostToolBatch":
            // A tool still unfinished here never ran to completion (denied or blocked): always a failure.
            var out: [NormalizerOutput] = []
            for call in p["tool_calls"]?.array ?? [] {
                guard let id = call["tool_use_id"]?.string, !finished.contains(id) else { continue }
                if !started.contains(where: { $0.id == id }) {
                    let s = Started(id: id, name: call["tool_name"]?.string ?? "", input: call["tool_input"] ?? .null, promptId: promptId)
                    started.append(s)
                    out.append(.event(.toolStarted(toolUseId: id, name: s.name, input: s.input, promptId: promptId)))
                }
                out += finish(id, ok: false, output: Self.output(of: call["tool_response"]), durationMs: nil)
            }
            return out
        case "UserPromptSubmit":
            // Blank lines left at either end by an unwrapped paste are not the message.
            let text = unwrappingPastes(p["prompt"]?.string ?? "").trimmingCharacters(in: .newlines)
            let m = sent.match(text)
            return [.event(.userMessage(text: m.text, promptId: promptId, origin: m.origin, attachments: m.attachments))]
        case "PermissionRequest":
            let input = p["tool_input"] ?? .null
            let match = started.last { !finished.contains($0.id) && $0.promptId == promptId && $0.input == input }
            return [.permissionRequest(toolName: p["tool_name"]?.string ?? "", input: input, suggestions: p["permission_suggestions"],
                                       promptId: promptId, toolUseId: match?.id)]
        case "Notification": return [.notification(type: p["notification_type"]?.string)]
        case "SessionStart":
            // A --resume launch (engine restart, crash relaunch) is the "Resumed after the restart" line of spec §4.2.
            let source = p["source"]?.string
            return [.sessionStarted(source: source)] + (source == "resume" ? [.event(.system(.resumed))] : [])
        case "SessionEnd": return [.sessionEnded(reason: p["reason"]?.string)]
        case "StopFailure":
            let reason = p["error"]?.string ?? p["matcher"]?.string ?? p["error_type"]?.string ?? "error"
            var out: [NormalizerOutput] = [.event(.turnFailed(reason: reason))]
            // The error fields themselves, never a mention elsewhere in the payload (the reply text could say "rate_limit").
            if ["error", "matcher", "error_type"].contains(where: { p[$0]?.string?.hasPrefix("rate_limit") == true }) {
                out.append(.rateLimited)
            }
            return out
        case "SubagentStart": return [.event(.subagent(started: true, agentType: p["agent_type"]?.string))]
        case "SubagentStop": return [.event(.subagent(started: false, agentType: p["agent_type"]?.string))]
        case "PreCompact": return [.event(.system(.compacted))]
        default: return []
        }
    }
}

/// The prompt with each multi-line paste unwrapped: Claude Code hands it to UserPromptSubmit as
/// `<pasted_content id="X">\n…\n</pasted_content id="X">` (seen live with 2.1.296), the newlines inside the tags its own.
func unwrappingPastes(_ prompt: String) -> String {
    pasteBlock.stringByReplacingMatches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt), withTemplate: "$2")
}

private let pasteBlock = try! NSRegularExpression(
    pattern: #"<pasted_content id="([^"]*)">\n([\s\S]*?)\n</pasted_content id="\1">"#)
