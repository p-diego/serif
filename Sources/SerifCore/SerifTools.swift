import Foundation

// Serif's tools for a bot (spec §4): the MCP stdio server "serif" (protocol 2025-06-18) that `serif-tools` runs,
// handing every call to the engine on hook.sock.

/// What a tool call gives back (spec §4): the text the model reads, and whether it is an error. It travels from the
/// engine as JSON in `HookReply.stdout`.
public struct ToolResult: Codable, Equatable, Sendable {
    public var text: String
    public var isError: Bool
    public init(_ text: String, isError: Bool = false) { self.text = text; self.isError = isError }

    /// No engine, a secret it refused, or no answer within the time limit (spec §10).
    public static let unreachable = ToolResult("Serif is not reachable", isError: true)
}

/// The seventeen tools as `tools/list` gives them (spec §4 of 0.5, §4–6 of 0.6); names and fields in English, like the
/// system prompt.
public let serifTools: [JSONValue] = [
    tool("send_message", "Send a message to another bot of this project: a task to do (its answer comes later as a new "
         + "message), a reply about an open task, or a note.",
         ["to": text("The bot's name"), "body": text("The whole message: the other bot sees nothing else"),
          "kind": ["type": "string", "enum": ["task", "reply", "note"]],
          "task_id": number("For a reply: the open task it is about"),
          "deadline_hours": ["type": "integer", "minimum": 1, "maximum": 168,
                             "description": "For a task: hours to finish it, 24 when left out"]],
         required: ["to", "body", "kind"]),
    tool("complete_task", "Close a task you were given, with your result: the bot that asked gets it.",
         ["task_id": number("The task's number"), "result": text("What you did and found; files by their path")],
         required: ["task_id", "result"]),
    tool("cancel_task", "Cancel a task you asked for; its bot is told.",
         ["task_id": number("The task's number"), "reason": text("Why, for the other bot")], required: ["task_id"]),
    tool("check_inbox", "Your open tasks, the tasks you asked for, and the messages that arrived while you were busy.",
         [:], required: []),
    tool("list_bots", "The bots of this project: name, role, state, agent.", [:], required: []),
    tool("create_bot", "Create a bot in this project, with your agent and your freedom; it introduces itself to the "
         + "user.",
         ["name": text("A name no other bot of the project has"), "instructions": text("Its role and how to work")],
         required: ["name", "instructions"]),
    tool("update_instructions", "Change your own instructions, or those of a bot you created. They apply from its next "
         + "start.",
         ["bot": text("The name of a bot you created; leave out for yourself"),
          "instructions": text("The new instructions")],
         required: ["instructions"]),
    tool("archive_bot", "Archive a bot you created; its open tasks are cancelled.",
         ["name": text("The bot's name")], required: ["name"]),
    // Routines, signals and decisions (spec §4–6 of 0.6)
    tool("create_routine", "Create a routine of yours: a prompt that runs as a turn of yours on a schedule, or when a "
         + "signal comes. Give exactly one of every_minutes, daily_at, weekdays_at, signal or cron.",
         ["name": text("A short name no routine of yours has"),
          "every_minutes": ["type": "integer", "minimum": 5, "description": "Run every N minutes, at least 5"],
          "daily_at": text("Run every day at this local time, \"HH:MM\""),
          "weekdays_at": ["type": "object", "description": "Run on these weekdays at this local time",
                          "properties": ["days": ["type": "array", "items": ["type": "integer", "minimum": 1, "maximum": 7],
                                                  "description": "1 = Monday … 7 = Sunday"],
                                         "time": text("\"HH:MM\"")],
                          "required": ["days", "time"]],
          "signal": text("Run when a bot of this project emits this signal (1–64 characters, no spaces)"),
          "cron": text("A five-field cron expression: minute hour day month weekday"),
          "prompt": text("What to do in each run; the whole job, as it runs alone"),
          "max_minutes": ["type": "integer", "minimum": 1, "maximum": 480,
                          "description": "A run longer than this is stopped; 30 when left out"],
          "notify": ["type": "boolean", "description": "Tell the user when a run finishes; true when left out"]],
         required: ["name", "prompt"]),
    tool("list_routines", "Your routines: when each runs, whether it is on, its next run and its last outcome.",
         [:], required: []),
    tool("set_routine_enabled", "Turn a routine of yours on or off.",
         ["name": text("The routine's name"), "enabled": ["type": "boolean"]], required: ["name", "enabled"]),
    tool("delete_routine", "Delete a routine of yours.", ["name": text("The routine's name")], required: ["name"]),
    tool("run_routine", "Run a routine of yours once, as soon as this turn ends.",
         ["name": text("The routine's name")], required: ["name"]),
    tool("emit_signal", "Announce an event: every routine of this project waiting for this signal runs, yours included.",
         ["name": text("The signal's name, 1–64 characters, no spaces"),
          "text": text("What happened, for the routines that run; 4 KB at most")], required: ["name"]),
    tool("raise_decision", "Ask the user to choose, when the choice is theirs: a question and 2–6 short options. Go on "
         + "with the rest of your work: the answer comes later as a message.",
         ["question": text("What they must decide"),
          "options": ["type": "array", "items": ["type": "string"], "minItems": 2, "maxItems": 6,
                      "description": "2 to 6 options, each up to 200 characters"],
          "recommendation": ["type": "integer", "minimum": 1, "maximum": 6,
                             "description": "The number of the option you recommend, 1 for the first"],
          "context": text("Why it matters and what you found; 4 KB at most")],
         required: ["question", "options"]),
    tool("list_decisions", "The decisions of this project, open and answered, with their answers.", [:], required: []),
    tool("withdraw_decision", "Take back an open decision you raised.",
         ["number": number("The decision's number"), "reason": text("Why, for the user")], required: ["number"]),
]

private func tool(_ name: String, _ description: String, _ properties: [String: JSONValue],
                  required: [String]) -> JSONValue {
    ["name": .string(name), "description": .string(description),
     "inputSchema": ["type": "object", "properties": .object(properties),
                     "required": .array(required.map(JSONValue.string))]]
}
private func text(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
private func number(_ description: String) -> JSONValue { ["type": "integer", "description": .string(description)] }

/// The answer to one MCP line (spec §3.3): `initialize`, `ping`, `tools/list`, and `tools/call` through `call`;
/// notifications get none, any other method "Method not found". One line, with no newline inside.
public func mcpReply(to line: Data, call: (String, JSONValue) -> ToolResult) -> String? {
    guard let message = try? JSONValue.parse(line), message.object != nil else {
        return rpc(.null, error: -32700, "Parse error")
    }
    guard let id = message["id"], let method = message["method"]?.string else { return nil }
    let params = message["params"] ?? [:]
    switch method {
    case "initialize":
        // The client's version when it is one of these, else the newest (MCP's version negotiation).
        let known = ["2024-11-05", "2025-03-26", "2025-06-18"]
        let asked = params["protocolVersion"]?.string ?? ""
        return rpc(id, result: ["protocolVersion": .string(known.contains(asked) ? asked : known[2]),
                                "capabilities": ["tools": [:]],
                                "serverInfo": ["name": "serif", "version": .string(SerifVersion.current)],
                                "instructions": .string(serifToolsGuide)])
    case "ping":
        return rpc(id, result: [:])
    case "tools/list":
        return rpc(id, result: ["tools": .array(serifTools)])
    case "tools/call":
        guard let name = params["name"]?.string else { return rpc(id, error: -32602, "Missing tool name") }
        let result = call(name, params["arguments"] ?? [:])
        return rpc(id, result: ["content": [["type": "text", "text": .string(result.text)]],
                                "isError": .bool(result.isError)])
    default:
        return rpc(id, error: -32601, "Method not found")
    }
}

private func rpc(_ id: JSONValue, result: JSONValue) -> String {
    (["jsonrpc": "2.0", "id": id, "result": result] as JSONValue).compactText
}
private func rpc(_ id: JSONValue, error code: Int, _ message: String) -> String {
    let error: JSONValue = ["code": .number(Double(code)), "message": .string(message)]
    return (["jsonrpc": "2.0", "id": id, "error": error] as JSONValue).compactText
}

/// Hands a tool call to the engine on hook.sock (spec §4), as the bot and its launch's secret the environment gives
/// (never the arguments). No answer within `timeout` seconds, or none worth reading, is "Serif is not reachable".
public func forwardTool(_ name: String, _ arguments: JSONValue, environment: [String: String],
                        timeout: TimeInterval = 10) -> ToolResult {
    let payload: JSONValue = ["tool": .string(name), "arguments": arguments]
    guard let socket = environment["SERIF_HOOK_SOCKET"], let bot = environment["SERIF_BOT_ID"],
          let token = environment["SERIF_TOKEN"],
          let line = try? protocolEncoder().encode(HookEnvelope(botId: bot, token: token, payload: payload)),
          let reply = LineClient.request(path: socket, line: line, timeout: timeout),
          let stdout = (try? protocolDecoder().decode(HookReply.self, from: reply))?.stdout,
          let result = try? JSONDecoder().decode(ToolResult.self, from: Data(stdout.utf8))
    else { return .unreachable }
    return result
}
