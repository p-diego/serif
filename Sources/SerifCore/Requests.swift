import Foundation

/// The kind of answer a card waits for. A `decision` (spec §6 of 0.6) is the one kind that does not hold its bot.
public enum WaitKind: String, Codable, Sendable { case permission, question, plan, decision }

/// A question or permission prompt raised by a bot, waiting for the user.
public struct PendingRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let botId: UUID
    public let kind: WaitKind
    public let toolName: String
    public let input: JSONValue
    public var toolUseId: String?
    public let promptId: String?
    public let suggestions: JSONValue?
    public let openedAt: Date
    /// The answers a Codex server accepts, in its order ("accept", "acceptForSession", "decline", "cancel"); nil for
    /// Claude Code's cards, whose buttons are fixed (spec §4).
    public var decisions: [String]?

    public init(id: UUID = UUID(), botId: UUID, kind: WaitKind, toolName: String, input: JSONValue,
                toolUseId: String?, promptId: String?, suggestions: JSONValue?, openedAt: Date = Date(), decisions: [String]? = nil) {
        self.id = id
        self.botId = botId
        self.kind = kind
        self.toolName = toolName
        self.input = input
        self.toolUseId = toolUseId
        self.promptId = promptId
        self.suggestions = suggestions
        self.openedAt = openedAt
        self.decisions = decisions
    }

    /// Questions and plan approvals have their own UI; every other tool is a permission prompt.
    public static func kind(forTool name: String) -> WaitKind {
        switch name {
        case "AskUserQuestion": .question
        case "ExitPlanMode": .plan
        default: .permission
        }
    }
}

/// How a request was closed.
public enum RequestResolution: String, Codable, Sendable { case answeredInApp, answeredInTerminal, cancelled }

/// The user's answer to a pending request.
public enum RequestAnswer: Codable, Equatable, Sendable {
    case allow, allowSession, deny(message: String?)
    case denyAndStop                      // Codex's "cancel": no, and the turn stops
    case answers([String: [String]])      // question text → chosen labels (one element unless multiSelect)
    case approvePlan, rejectPlan(message: String)
    case decision(option: Int?, text: String?)    // a decision card: the option's index, words, or both (spec §6 of 0.6)
}

/// What the hook relay does once the user has answered a request.
public enum HookOutcome: Equatable, Sendable {
    case reply(String)          // print this JSON on serif-hook stdout
    case silent                 // let serif-hook exit printing nothing
    case typeInTerminal(String) // send these keys to the PTY (approve plan: "2"), then silent
}

/// Maps a user answer to what serif-hook must do, using the hook output shape Claude Code accepted in the live probe.
/// An answer that does not fit the request's kind yields `.silent`.
public func hookOutcome(for answer: RequestAnswer, request: PendingRequest) -> HookOutcome {
    switch (answer, request.kind) {
    case (.allow, .permission):
        return decisionReply(["behavior": .string("allow")])
    case (.allowSession, .permission):
        var decision: [String: JSONValue] = ["behavior": .string("allow")]
        if let updates = sessionPermissions(request.suggestions) {
            decision["updatedPermissions"] = .array(updates)
        }
        return decisionReply(decision)
    case (.deny(let message), .permission), (.deny(let message), .question), (.deny(let message), .plan):
        return denyReply(message ?? "The user denied this action.")
    case (.answers(let answers), .question):
        var input = request.input.object ?? [:]
        input["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
        return decisionReply(["behavior": .string("allow"), "updatedInput": .object(input)])
    case (.approvePlan, .plan):
        return .typeInTerminal("2")
    case (.rejectPlan(let message), .plan):
        return denyReply(message)
    default:
        return .silent
    }
}

private func decisionReply(_ decision: [String: JSONValue]) -> HookOutcome {
    hookReply(.object(["hookSpecificOutput": .object([
        "hookEventName": .string("PermissionRequest"),
        "decision": .object(decision),
    ])]))
}

private func denyReply(_ message: String) -> HookOutcome {
    decisionReply(["behavior": .string("deny"), "message": .string(message)])
}

/// Copies Claude Code's permission suggestions with their destination moved to the session; nil when there are none.
private func sessionPermissions(_ suggestions: JSONValue?) -> [JSONValue]? {
    guard let items = suggestions?.array, !items.isEmpty else { return nil }
    return items.map { item in
        guard var object = item.object else { return item }
        object["destination"] = .string("session")
        return .object(object)
    }
}

/// Encodes a hook payload; a value that cannot be encoded is treated as a silent exit rather than a crash.
private func hookReply(_ value: JSONValue) -> HookOutcome {
    guard let data = try? value.encoded(), let text = String(data: data, encoding: .utf8) else { return .silent }
    return .reply(text)
}

/// One question of an AskUserQuestion request.
public struct QuestionSpec: Equatable, Sendable {
    public let text: String
    public let header: String?
    public let multiSelect: Bool
    public let options: [Option]
    public struct Option: Equatable, Sendable {
        public let label: String
        public let description: String?
    }

    init?(_ v: JSONValue) {
        guard let text = v["question"]?.string else { return nil }
        self.text = text
        header = v["header"]?.string
        multiSelect = v["multiSelect"]?.bool ?? false
        options = (v["options"]?.array ?? []).compactMap { o in
            o["label"]?.string.map { Option(label: $0, description: o["description"]?.string) }
        }
    }
}

public func questionSpecs(_ request: PendingRequest) -> [QuestionSpec] {
    (request.input["questions"]?.array ?? []).compactMap(QuestionSpec.init)
}

/// The answer for the picked labels per question index; labels come out in option order, whatever order they were picked in.
public func questionAnswer(_ questions: [QuestionSpec], chosen: [Int: [String]]) -> RequestAnswer {
    var out: [String: [String]] = [:]
    for (i, q) in questions.enumerated() {
        let picked = chosen[i] ?? []
        out[q.text] = q.options.map(\.label).filter(picked.contains)
    }
    return .answers(out)
}

/// What answers a Codex server's request (spec §4), or nil when `answer` does not fit it: a decision it offered, a
/// question's choices by question id, or for extra permissions the ones asked for (this turn or the session) or none.
public func codexReply(for answer: RequestAnswer, request: PendingRequest) -> JSONValue? {
    switch (answer, request.toolName) {
    case let (.answers(chosen), "AskUserQuestion"):
        // The card keys answers by question text; Codex wants them by question id.
        var out: [String: JSONValue] = [:]
        for q in request.input["questions"]?.array ?? [] {
            guard let id = q["id"]?.string, let text = q["question"]?.string else { continue }
            out[id] = ["answers": .array((chosen[text] ?? []).map(JSONValue.string))]
        }
        return ["answers": .object(out)]
    case (.allow, "Permissions"): return ["permissions": request.input["permissions"] ?? [:], "scope": "turn"]
    case (.allowSession, "Permissions"): return ["permissions": request.input["permissions"] ?? [:], "scope": "session"]
    case (.deny, "Permissions"): return ["permissions": [:]]
    default:
        let decision: String
        switch answer {
        case .allow: decision = "accept"
        case .allowSession: decision = "acceptForSession"
        case .deny: decision = "decline"
        case .denyAndStop: decision = "cancel"
        default: return nil
        }
        guard request.decisions?.contains(decision) == true else { return nil }
        return ["decision": .string(decision)]
    }
}
