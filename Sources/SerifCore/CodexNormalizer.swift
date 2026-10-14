import Foundation

/// Turns a Codex app-server's notifications and requests into the chat events and cards Claude Code bots produce (spec
/// §4). Unlike hooks they come on one ordered channel, so nothing is held back. Tool items take Claude Code's tool names
/// ("Bash", "Edit", "WebSearch", "mcp__server__tool", "Agent"), so steps, activity and cards read the same for both agents.
public struct CodexNormalizer {
    private struct Step { let name: String; let input: JSONValue; let ok: Bool; let output: String }

    private var sent = SentMessages()
    private var started: [String: Step] = [:]       // tool items begun and not finished: a step can close after its turn
    private var pending: [String: String] = [:]     // per agent message, streamed text not emitted yet (its unfinished line)
    private var streamed: [String: String] = [:]    // per agent message, all its streamed text
    private var parts: [String: Int] = [:]          // per agent message, the events emitted (their `index`)
    private var answer: String?                     // the turn's last answer, for `turnEnded`

    public init() {}

    /// A text Serif is sending (spec §4): its user message gets `origin`; anything else was typed in the terminal.
    public mutating func expectChatMessage(_ text: String, origin: MessageOrigin = .chat) { sent.expect(text, origin: origin) }

    public mutating func ingest(_ message: CodexMessage) -> [NormalizerOutput] {
        switch message {
        case let .notification(method, p): notification(method, p)
        case let .request(id, method, p): request(id, method, p)
        case .response, .failure: []
        }
    }

    private mutating func notification(_ method: String, _ p: JSONValue) -> [NormalizerOutput] {
        let turn = p["turnId"]?.string
        switch method {
        case "turn/started":
            answer = nil
            return []
        case "item/started":
            guard let item = p["item"], let id = item["id"]?.string, let step = Self.step(item) else { return [] }
            started[id] = step
            return [.event(.toolStarted(toolUseId: id, name: step.name, input: step.input, promptId: turn))]
        case "item/agentMessage/delta":
            guard let id = p["itemId"]?.string, let delta = p["delta"]?.string else { return [] }
            streamed[id, default: ""] += delta
            pending[id, default: ""] += delta
            // Whole lines only, like Claude Code's MessageDisplay: one event per line, not one per word.
            guard delta.contains("\n"), let text = pending[id], let newline = text.lastIndex(of: "\n") else { return [] }
            pending[id] = String(text[text.index(after: newline)...])
            return emit(id, String(text[...newline]), final: false, turn: turn)
        case "item/completed":
            guard let item = p["item"] else { return [] }
            return completed(item, turn: turn)
        case "serverRequest/resolved":
            return p["requestId"].map { [.serverRequestResolved(id: $0)] } ?? []
        case "turn/completed":
            let t = p["turn"]
            // A reply cut short (interrupted, failed) may get no item/completed: what streamed of it closes here.
            var out: [NormalizerOutput] = []
            for (id, rest) in pending.sorted(by: { $0.key < $1.key }) where !rest.isEmpty || parts[id] != nil {
                out += emit(id, rest, final: true, turn: t?["id"]?.string)
            }
            (pending, streamed, parts) = ([:], [:], [:])
            switch t?["status"]?.string {
            case "interrupted": out.append(.event(.turnInterrupted))
            case "failed":
                let error = t?["error"]
                out.append(.event(.turnFailed(reason: Self.reason(error))))
                if ["usageLimitExceeded", "rateLimitExceeded"].contains(error?["codexErrorInfo"]?.string ?? "") { out.append(.rateLimited) }
            default:
                out.append(.event(.turnEnded(promptId: t?["id"]?.string, lastMessage: answer)))
            }
            return out
        default:
            return []
        }
    }

    private mutating func completed(_ item: JSONValue, turn: String?) -> [NormalizerOutput] {
        guard let id = item["id"]?.string else { return [] }
        switch item["type"]?.string {
        case "userMessage":
            let text = (item["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
            return [.event(.userMessage(text: text, promptId: turn, origin: sent.origin(of: text)))]
        case "agentMessage":
            // Commentary and final answer are both the bot's messages (spec §4); the last answer closes the turn.
            let text = item["text"]?.string ?? ""
            if item["phase"]?.string != "commentary" { answer = text }
            let whole = streamed.removeValue(forKey: id)
            let rest = pending.removeValue(forKey: id) ?? (whole == nil ? text : "")
            var out = rest.isEmpty && parts[id] == nil ? [] : emit(id, rest, final: true, turn: turn)
            if let whole, whole != text { out.append(.event(.assistantTextReplaced(messageId: id, text: text))) }
            parts[id] = nil
            return out
        case "contextCompaction":
            return [.event(.system(.compacted))]
        default:
            guard let step = Self.step(item) else { return [] }
            var out: [NormalizerOutput] = []
            // Never seen starting (it began before a restart): started now, so the chat has both ends.
            if started.removeValue(forKey: id) == nil {
                out.append(.event(.toolStarted(toolUseId: id, name: step.name, input: step.input, promptId: turn)))
            }
            out.append(.event(.toolFinished(toolUseId: id, ok: step.ok, output: step.output, durationMs: item["durationMs"]?.int)))
            return out
        }
    }

    private mutating func emit(_ id: String, _ text: String, final: Bool, turn: String?) -> [NormalizerOutput] {
        let index = parts[id, default: 0]
        parts[id] = index + 1
        return [.event(.assistantText(messageId: id, index: index, delta: text, final: final, promptId: turn))]
    }

    private mutating func request(_ id: JSONValue, _ method: String, _ p: JSONValue) -> [NormalizerOutput] {
        let (turn, item, reason) = (p["turnId"]?.string, p["itemId"]?.string, p["reason"]?.string)
        func card(_ tool: String, _ input: [String: JSONValue], _ decisions: [String]?) -> [NormalizerOutput] {
            var input = input
            if let reason { input["description"] = .string(reason) }
            return [.serverRequest(id: id, toolName: tool, input: .object(input), decisions: decisions, turnId: turn, itemId: item)]
        }
        switch method {
        case "item/commandExecution/requestApproval":
            return card("Bash", ["command": .string(Self.command(p))], Self.decisions(p))
        case "item/fileChange/requestApproval":
            // The request does not name the files; the step that started just before does.
            return card("Edit", item.flatMap { started[$0]?.input.object } ?? [:], Self.decisions(p))
        case "item/permissions/requestApproval":
            return card("Permissions", ["permissions": p["permissions"] ?? [:]], ["accept", "acceptForSession", "decline"])
        case "item/tool/requestUserInput":
            // Same shape as Claude Code's AskUserQuestion (question, header, options with label and description).
            return card("AskUserQuestion", ["questions": p["questions"] ?? []], nil)
        default:
            return []       // the engine answers what it does not show with an error (spec §8)
        }
    }

    /// The decisions a card offers, in Codex's order (spec §4): those it sent among accept, acceptForSession, decline and
    /// cancel; the permanent rule (acceptWithExecpolicyAmendment) is the terminal's. Without a list, all four; with none of
    /// them, accept, decline and cancel, which Codex takes even unlisted (spike prova 3): a card can always be answered.
    static func decisions(_ p: JSONValue) -> [String] {
        let known = ["accept", "acceptForSession", "decline", "cancel"]
        guard let offered = p["availableDecisions"]?.array else { return known }
        let usable = offered.compactMap(\.string).filter(known.contains)
        return usable.isEmpty ? ["accept", "decline", "cancel"] : usable
    }

    /// The command as typed ("echo ciao"), not the shell wrapper Codex runs it in ("/bin/zsh -lc 'echo ciao'").
    private static func command(_ v: JSONValue) -> String {
        let actions = v["commandActions"]?.array ?? []
        return (actions.count == 1 ? actions[0]["command"]?.string : nil) ?? v["command"]?.string ?? ""
    }

    /// A tool item as a step: commands, file changes, MCP calls, web searches and sub-agents; nil for anything else.
    private static func step(_ item: JSONValue) -> Step? {
        let status = item["status"]?.string
        let ok = status == "completed" && (item["exitCode"]?.int ?? 0) == 0
        switch item["type"]?.string {
        case "commandExecution":
            let output = status == "declined" ? "Declined" : truncatedOutput(item["aggregatedOutput"]?.string ?? "")
            return Step(name: "Bash", input: ["command": .string(command(item))], ok: ok, output: output)
        case "fileChange":
            let changes = item["changes"]?.array ?? []
            let paths = changes.compactMap { $0["path"]?.string }
            let diff = truncatedOutput(changes.compactMap { $0["diff"]?.string }.joined(separator: "\n"))
            return Step(name: "Edit", input: ["file_path": .string(paths.first ?? ""), "content": .string(diff)], ok: ok,
                        output: status == "declined" ? "Declined" : paths.joined(separator: "\n"))
        case "mcpToolCall":
            let text = (item["result"]?["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
            return Step(name: "mcp__\(item["server"]?.string ?? "")__\(item["tool"]?.string ?? "")", input: item["arguments"] ?? [:],
                        ok: ok, output: truncatedOutput(item["error"]?["message"]?.string ?? text))
        case "webSearch":
            return Step(name: "WebSearch", input: ["query": .string(item["query"]?.string ?? "")], ok: true, output: "")
        case "collabAgentToolCall":
            return Step(name: "Agent", input: ["description": .string(item["prompt"]?.string ?? "")], ok: ok, output: "")
        default:
            return nil
        }
    }

    /// Codex's message for a failed turn; an API error comes as JSON text, of which the inner message is the readable part.
    private static func reason(_ error: JSONValue?) -> String {
        let message = error?["message"]?.string ?? "Codex failed"
        return (try? JSONValue.parse(Data(message.utf8)))?["error"]?["message"]?.string ?? message
    }
}
