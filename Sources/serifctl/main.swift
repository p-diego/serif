import Foundation
import SerifCore

// Dev-only helper: talks to a running serifd (honours SERIF_HOME) to populate it for screenshots. Not part of the app bundle.
let args = Array(CommandLine.arguments.dropFirst())
let socket = SerifPaths.standard().engineSocket.path
let encoder = protocolEncoder(), decoder = protocolDecoder()

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }

// Pushes may arrive before the response: keep reading until the response with our id.
func call(_ request: AppRequest) -> ResponseBody {
    let queue = DispatchQueue(label: "serifctl")
    guard let line = try? encoder.encode(RequestEnvelope(id: 1, request: request)),
          let connection = LineClient.connect(path: socket, queue: queue) else { fail("no answer from serifd at \(socket)") }
    let done = DispatchSemaphore(value: 0)
    var result: ResponseBody?
    connection.onLine = { data in
        if result == nil, case .response(1, let body)? = try? decoder.decode(EngineMessage.self, from: data) { result = body; done.signal() }
    }
    connection.send(line)
    guard done.wait(timeout: .now() + 10) == .success, let body = result else { fail("no response from serifd") }
    queue.sync { connection.close() }
    if case .error(let message) = body { fail("error: \(message)") }
    return body
}

func snapshot() -> Snapshot {
    guard case .snapshot(let s) = call(.snapshot) else { fail("unexpected reply") }
    return s
}

func uuid(_ s: String) -> UUID { guard let u = UUID(uuidString: s) else { fail("bad id: \(s)") }; return u }

switch args.first {
case "snapshot":
    let s = snapshot()
    for p in s.projects { print("project \(p.id) \(p.name)") }
    for b in s.bots { print("bot \(b.bot.id) \(b.bot.projectId) \(b.bot.name) \(b.state) unread=\(b.unread) preview=\(b.preview ?? "-")") }
    for r in s.requests { print("request \(r.id) bot=\(r.botId) \(r.toolName)") }
case "create-project" where args.count >= 2:
    guard case .project(let p) = call(.createProject(name: args[1], linkedFolder: nil, readLinkedInstructions: false)) else { fail("unexpected reply") }
    print(p.id)
case "create-bot" where args.count >= 3:
    let existing = snapshot().bots.map(\.bot.face)
    let new = NewBot(projectId: uuid(args[1]), name: args[2], face: randomFace(existing: existing), agent: .claude,
                     model: args.count > 3 ? args[3] : nil, instructions: "", freedom: .ask)
    guard case .bot(let b) = call(.createBot(new)) else { fail("unexpected reply") }
    print(b.id)
case "send" where args.count >= 3:
    _ = call(.send(botId: uuid(args[1]), text: args[2...].joined(separator: " "))); print("ok")
case "answer-allow" where args.count >= 2:
    _ = call(.answer(requestId: uuid(args[1]), answer: .allow)); print("ok")
case "mark-read" where args.count >= 2:
    _ = call(.markRead(botId: uuid(args[1]), seq: Int.max / 2)); print("ok")
case "pin" where args.count >= 2:
    guard var bot = snapshot().bots.first(where: { $0.bot.id == uuid(args[1]) })?.bot else { fail("unknown bot") }
    bot.pinned.toggle(); _ = call(.updateBot(bot)); print("pinned=\(bot.pinned)")
case "stop" where args.count >= 2:
    _ = call(.interrupt(botId: uuid(args[1]))); print("ok")
case "freedom" where args.count >= 3:
    guard var bot = snapshot().bots.first(where: { $0.bot.id == uuid(args[1]) })?.bot,
          let freedom = Freedom(rawValue: args[2]) else { fail("unknown bot or freedom") }
    bot.freedom = freedom; _ = call(.updateBot(bot)); print("freedom=\(freedom)")
case "terminal" where args.count >= 2:
    // Shows the bot's terminal without the app: steps are seconds to wait, or text typed (ENTER, ESC: those keys; text
    // gets Enter). Writes everything the terminal shows to stdout, raw.
    let bot = uuid(args[1]), queue = DispatchQueue(label: "serifctl")
    guard let connection = LineClient.connect(path: socket, queue: queue) else { fail("no answer from serifd at \(socket)") }
    connection.onLine = { data in
        switch try? decoder.decode(EngineMessage.self, from: data) {
        case .response(_, .terminal(_, let d))?: FileHandle.standardOutput.write(d)
        case .response(_, .error(let m))?: fail("error: \(m)")
        case .push(.terminalOutput(bot, _, let d))?: FileHandle.standardOutput.write(d)
        default: break
        }
    }
    var id = 0
    let send = { (r: AppRequest) in id += 1; if let line = try? encoder.encode(RequestEnvelope(id: id, request: r)) { connection.send(line) } }
    send(.resizeTerminal(botId: bot, cols: 120, rows: 40))
    send(.attachTerminal(botId: bot))
    for step in args.dropFirst(2) {
        if let seconds = Double(step) { Thread.sleep(forTimeInterval: seconds); continue }
        let keys = ["ENTER": "\r", "ESC": "\u{1b}"][step] ?? step + "\r"
        send(.terminalInput(botId: bot, data: Data(keys.utf8)))
    }
    send(.detachTerminal(botId: bot))
    Thread.sleep(forTimeInterval: 0.5)
    queue.sync { connection.close() }
default:
    fail("usage: serifctl snapshot | create-project <name> | create-bot <projectId> <name> [model] | send <botId> <text> | answer-allow <requestId> | mark-read <botId> | pin <botId> | stop <botId> | freedom <botId> ask|edits|auto | terminal <botId> [seconds | text | ENTER | ESC]...")
}
