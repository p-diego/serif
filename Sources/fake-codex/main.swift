import Foundation
import Network
import CryptoKit
import SerifCore

// Stands in for `codex` in the tests (never the real one): its checks, its app-server (WebSocket JSON-RPC, answering
// like Codex 0.160 and playing a scenario) and its terminal (`codex resume`).
let env = ProcessInfo.processInfo.environment
let args = Array(CommandLine.arguments.dropFirst())

/// One line per launch in SERIF_FAKE_LOG, as fake-claude writes it (plus the folder it ran in).
func logLaunch() {
    guard let path = env["SERIF_FAKE_LOG"] else { return }
    let line: JSONValue = ["args": .array(args.map(JSONValue.string)), "env": .object(env.mapValues(JSONValue.string)),
                           "cwd": .string(FileManager.default.currentDirectoryPath)]
    append(line.compactText, to: path)
}

/// One write with O_APPEND: several servers (bots', the catalog's) write the same files at once, and none may lose a line.
func append(_ line: String, to path: String) {
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    _ = Array((line + "\n").utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    close(fd)
}

func value(after flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }

switch args.first {
case "--version":
    print("codex-cli 0.160.0")
    exit(0)
case "login":
    // Like 0.160.0, the answer goes to standard error. Signed out while the file SERIF_FAKE_CODEX_LOGGED_OUT names exists.
    if let flag = env["SERIF_FAKE_CODEX_LOGGED_OUT"], FileManager.default.fileExists(atPath: flag) {
        FileHandle.standardError.write(Data("Not logged in\n".utf8)); exit(1)
    }
    FileHandle.standardError.write(Data("Logged in using ChatGPT\n".utf8))
    exit(0)
case "resume":
    // The terminal: says which thread it shows and whether it got the secret, then echoes what is typed. With
    // SERIF_FAKE_CODEX_TUI_STUBBORN it ignores SIGTERM, so only the SIGKILL 3 s later ends it.
    logLaunch()
    if env["SERIF_FAKE_CODEX_TUI_STUBBORN"] != nil { signal(SIGTERM, SIG_IGN) }
    print("CODEX-TUI \(args.last ?? "") \(env["SERIF_CODEX_TOKEN"].map { _ in "token" } ?? "no-token")\r")
    var buffer = [UInt8](repeating: 0, count: 1024)
    while case let n = read(0, &buffer, buffer.count), n > 0 { FileHandle.standardOutput.write(Data(buffer[0..<n])) }
    exit(0)
case "app-server":
    break
default:
    exit(2)
}

logLaunch()
let queue = DispatchQueue(label: "fake-codex")
// Never outlives whoever started it (watched from here, before any delay): a test that crashes before its tearDown would
// leave it listening forever.
let parent = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: queue)
parent.setEventHandler { exit(0) }
parent.resume()
// The port was taken (spec §8): exits like Codex would, once per flag file.
if let busy = env["SERIF_FAKE_CODEX_BUSY"], FileManager.default.fileExists(atPath: busy) {
    try? FileManager.default.removeItem(atPath: busy)
    FileHandle.standardError.write(Data("Error: address already in use\n".utf8))
    exit(1)
}
if let delay = env["SERIF_FAKE_CODEX_DELAY"].flatMap(Double.init) { usleep(UInt32(delay * 1_000_000)) }

// The scenario: lines {"reply": method, "result"|"error": …} answer that method's next request instead of the default,
// "delay" seconds later if given (that request's "after" too), or with "exit": code never (the server exits at once);
// {"after": method|"answer", "send": [messages], "exit": code} act once after the next such request (or answer to a
// server request). In what is sent, "$THREAD", "$TURN" and "$INPUT" are the thread, the last turn and the last text sent.
var replies: [(method: String, line: JSONValue)] = []
var afters: [(method: String, line: JSONValue)] = []
if let path = env["SERIF_FAKE_CODEX_SCENARIO"], let text = try? String(contentsOfFile: path, encoding: .utf8) {
    for line in text.split(separator: "\n") {
        guard let v = try? JSONValue.parse(Data(line.utf8)) else { continue }
        if let m = v["reply"]?.string { replies.append((m, v)) }
        if let m = v["after"]?.string { afters.append((m, v)) }
    }
}

let disabled = Set(args.indices.filter { args[$0] == "--disable" && $0 + 1 < args.count }.map { args[$0 + 1] })
var thread = "thr-1", turn = "", input = "", turns = 0
var hooksOn = !disabled.contains("hooks")
var connection: NWConnection?

func send(_ text: String) {
    let meta = NWProtocolWebSocket.Metadata(opcode: .text)
    connection?.send(content: Data(text.utf8), contentContext: NWConnection.ContentContext(identifier: "m", metadata: [meta]),
                     completion: .contentProcessed { _ in })
}

func fill(_ v: JSONValue) -> String {
    v.compactText.replacingOccurrences(of: "$THREAD", with: thread).replacingOccurrences(of: "$TURN", with: turn)
        .replacingOccurrences(of: "$INPUT", with: String(JSONValue.string(input).compactText.dropFirst().dropLast()))
}

/// Codex's answer when the scenario gives none. Isolation is reported from this server's own flags, and a thread's
/// `config` with `features` turns the hooks back on, as Codex 0.160 does (spec §3.6).
func defaultResult(_ method: String, _ p: JSONValue) -> JSONValue? {
    switch method {
    case "initialize": return ["userAgent": "fake-codex/0.160.0", "platformFamily": "unix", "platformOs": "macos"]
    case "thread/start", "thread/resume":
        if let id = p["threadId"]?.string { thread = id }
        if let features = p["config"]?["features"] { hooksOn = features["hooks"]?.bool ?? true }
        return ["thread": ["id": .string(thread), "status": ["type": "idle"]]]
    case "experimentalFeature/list":
        return ["data": [["name": "hooks", "enabled": .bool(hooksOn)], ["name": "apps", "enabled": .bool(!disabled.contains("apps"))]]]
    case "mcpServerStatus/list":
        return ["data": disabled.contains("apps") ? [] : [["name": "codex_apps", "pluginId": .null]]]
    case "turn/start":
        turns += 1
        turn = "turn-\(turns)"
        return ["turn": ["id": .string(turn), "status": "inProgress"]]
    case "turn/steer": return ["turnId": .string(turn)]
    case "turn/interrupt": return [:]
    case "plugin/list":
        return ["marketplaces": [
            ["name": "openai-bundled", "plugins": [
                ["id": "browser@openai-bundled", "name": "browser", "installed": true, "source": ["type": "local", "path": "/p/browser"]],
                ["id": "visualize@openai-bundled", "name": "visualize", "installed": true, "source": ["type": "local", "path": "/p/visualize"]],
                ["id": "unused@openai-bundled", "name": "unused", "installed": false, "source": ["type": "local", "path": "/p/unused"]]]],
            ["name": "openai-curated-remote", "plugins": [
                ["id": "work-pets@openai-curated-remote", "name": "work-pets", "installed": true, "source": ["type": "remote"]]]]]]
    case "skills/list":
        return ["data": [["cwd": "/", "skills": [["name": "work-pets:pets", "pluginId": "work-pets@openai-curated-remote"],
                                                  ["name": "imagegen", "pluginId": .null]]]]]
    case "model/list":
        return ["data": [["id": "gpt-6-luna", "displayName": "GPT-6-Luna", "hidden": false, "isDefault": true],
                         ["id": "gpt-5.6-terra", "displayName": "GPT-5.6-Terra", "hidden": false, "isDefault": false]]]
    default: return nil
    }
}

func received(_ data: Data) {
    if let path = env["SERIF_FAKE_CODEX_RPC"] { append(String(decoding: data, as: UTF8.self), to: path) }
    guard let v = try? JSONValue.parse(data) else { return }
    let method = v["method"]?.string, p = v["params"] ?? [:]
    if let text = p["input"]?.array?.first?["text"]?.string { input = text }
    if method == nil, v["id"] != nil { return act(after: "answer") }        // the answer to one of our requests
    guard let method, let id = v["id"] else { return }                        // notifications (initialized) need nothing
    let answer: String
    var delay = 0.0
    if let i = replies.firstIndex(where: { $0.method == method }) {
        let line = replies.remove(at: i).line
        if let code = line["exit"]?.int { exit(Int32(code)) }
        delay = line["delay"]?.double ?? 0
        if let error = line["error"]?.string { answer = codexErrorResponse(id: id, message: error) }
        else { _ = defaultResult(method, p); answer = codexResponse(id: id, result: line["result"] ?? [:]) }
    } else if let result = defaultResult(method, p) {
        answer = codexResponse(id: id, result: result)
    } else {
        answer = codexErrorResponse(id: id, message: "unknown method \(method)")
    }
    let reply = { send(answer); act(after: method) }
    if delay > 0 { queue.asyncAfter(deadline: .now() + delay, execute: reply) } else { reply() }
}

func act(after method: String) {
    guard let i = afters.firstIndex(where: { $0.method == method }) else { return }
    let line = afters.remove(at: i).line
    for message in line["send"]?.array ?? [] { send(fill(message)) }
    if let code = line["exit"]?.int { queue.asyncAfter(deadline: .now() + 0.2) { exit(Int32(code)) } }
}

func receive(_ c: NWConnection) {
    c.receiveMessage { data, _, _, error in
        if let data, !data.isEmpty { received(data) }
        if error == nil { receive(c) }
    }
}

// The WebSocket on 127.0.0.1 and the port given; only a client with the secret whose SHA-256 is --ws-token-sha256 gets in.
guard let listen = value(after: "--listen"), let port = listen.split(separator: ":").last.flatMap({ UInt16($0) }),
      let hash = value(after: "--ws-token-sha256") else { exit(2) }
let ws = NWProtocolWebSocket.Options()
ws.autoReplyPing = true
ws.setClientRequestHandler(queue) { _, headers in
    let bearer = headers.first { $0.name.lowercased() == "authorization" }?.value ?? ""
    let ok = bearer.hasPrefix("Bearer ") && codexTokenHash(String(bearer.dropFirst(7))) == hash
    return NWProtocolWebSocket.Response(status: ok ? .accept : .reject, subprotocol: nil)
}
let parameters = NWParameters.tcp
parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
guard let listener = try? NWListener(using: parameters) else { exit(1) }
listener.newConnectionHandler = { c in
    connection = c            // one client at a time is enough here
    c.start(queue: queue)
    receive(c)
}
listener.stateUpdateHandler = { if case .failed = $0 { exit(1) } }
listener.start(queue: queue)
dispatchMain()
