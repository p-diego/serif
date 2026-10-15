import Foundation
import SerifCore

// Scenario player standing in for the interactive `claude` TUI (tests only).
let env = ProcessInfo.processInfo.environment

// Claude Code's own checks, as the engine runs them before a launch (AgentCheck): answered at once, outside the scenario
// and the launch log. Signed out while the file SERIF_FAKE_LOGGED_OUT names exists.
switch Array(CommandLine.arguments.dropFirst()) {
case ["--version"]:
    print("2.1.296 (Claude Code)")
    exit(0)
case ["auth", "status"]:
    if let flag = env["SERIF_FAKE_LOGGED_OUT"], FileManager.default.fileExists(atPath: flag) {
        print(#"{"loggedIn": false, "authMethod": "none"}"#)
        exit(1)
    }
    print(#"{"loggedIn": true, "authMethod": "claude.ai", "email": "bot@example.com"}"#)
    exit(0)
default:
    break
}

// Raw stdin, like a real TUI: PTY input bytes arrive unmodified.
var attrs = termios()
if tcgetattr(0, &attrs) == 0 { cfmakeraw(&attrs); tcsetattr(0, TCSANOW, &attrs) }

func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

if let log = env["SERIF_FAKE_LOG"] {
    let obj: [String: Any] = ["args": Array(CommandLine.arguments.dropFirst()), "env": env]
    if var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
        data.append(0x0A)
        if let h = FileHandle(forWritingAtPath: log) ?? { FileManager.default.createFile(atPath: log, contents: nil); return FileHandle(forWritingAtPath: log) }() {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        }
    }
}

var input = Data()
var lastPaste = ""          // the text of the last bracketed paste `waitPaste` read: "$PASTE" in later hooks
func readStdin() -> Bool {
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(0, &buf, buf.count)
    if n <= 0 { return false }
    input.append(contentsOf: buf[0..<n])
    return true
}

// Background hooks still running, so `killHooks` can end them (like Claude Code killing a hook on Esc).
let asyncHooksLock = NSLock()
var asyncHooks: [Process] = []

func runHook(_ payload: Any, started: (Process) -> Void = { _ in }) {
    guard let bin = env["SERIF_HOOK_BIN"], var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    if let transcript = env["SERIF_FAKE_TRANSCRIPT"] {   // "$TRANSCRIPT" in a payload: the test's transcript file
        data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "$TRANSCRIPT", with: transcript).utf8)
    }
    if let pasted = try? JSONEncoder().encode(lastPaste) {   // "$PASTE": the last paste, as a JSON string
        data = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"$PASTE\"", with: String(decoding: pasted, as: UTF8.self)).utf8)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.environment = env
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    guard (try? p.run()) != nil else { return }
    started(p)
    inPipe.fileHandleForWriting.write(data)
    try? inPipe.fileHandleForWriting.close()
    let result = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if !result.isEmpty { out("HOOK-OUT:" + String(decoding: result, as: UTF8.self)) }
}

/// Calls one of Serif's tools as Claude Code does (spec §4): the "serif" server of the `--mcp-config` file, started
/// with that file's environment in place of this process's SERIF_* variables; initialize, then the call. Prints
/// "TOOL-OUT:<text>", with " (error)" for an error.
func runTool(_ call: JSONValue) {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let i = args.firstIndex(of: "--mcp-config"), i + 1 < args.count,
          let data = FileManager.default.contents(atPath: args[i + 1]),
          let serif = (try? JSONValue.parse(data))?["mcpServers"]?["serif"], let command = serif["command"]?.string
    else { return out("TOOL-OUT:no serif server\r\n") }
    let own = serif["env"]?.object?.compactMapValues(\.string) ?? [:]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: command)
    p.environment = env.filter { !$0.key.hasPrefix("SERIF_") }.merging(own) { $1 }
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    guard (try? p.run()) != nil else { return out("TOOL-OUT:cannot start \(command)\r\n") }
    let lines: [JSONValue] = [
        ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]],
        ["jsonrpc": "2.0", "method": "notifications/initialized"],
        ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": call]]
    inPipe.fileHandleForWriting.write(Data(lines.map { $0.compactText + "\n" }.joined().utf8))
    try? inPipe.fileHandleForWriting.close()
    let replies = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let result = replies.split(separator: 0x0A).compactMap { try? JSONValue.parse(Data($0)) }
        .first { $0["id"] == 2 }?["result"]
    let text = result?["content"]?.array?.first?["text"]?.string ?? "no answer"
    out("TOOL-OUT:\(text)\(result?["isError"] == true ? " (error)" : "")\r\n")
}

if let path = env["SERIF_FAKE_SCENARIO"], let text = try? String(contentsOfFile: path, encoding: .utf8) {
    for line in text.split(separator: "\n") {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        if let s = obj["print"] as? String { out(s) }
        else if let w = obj["waitInput"] as? String {
            let needle = Data(w.utf8)
            while true {
                if let r = input.range(of: needle) {
                    // "unexpected": printed when other input came before the match (e.g. a paste that should have waited).
                    if r.lowerBound != input.startIndex, let label = obj["unexpected"] as? String { out(label) }
                    input = Data(input[r.upperBound...]); break    // consume through the match
                }
                if !readStdin() { exit(0) }
            }
        }
        else if obj["waitPaste"] != nil {
            // The next bracketed paste and its Enter, as BotHost.typeMessage sends them.
            let start = Data("\u{1B}[200~".utf8), end = Data("\u{1B}[201~\r".utf8)
            while true {
                if let s = input.range(of: start), let e = input.range(of: end, in: s.upperBound..<input.endIndex) {
                    lastPaste = String(decoding: input[s.upperBound..<e.lowerBound], as: UTF8.self)
                    input = Data(input[e.upperBound...]); break
                }
                if !readStdin() { exit(0) }
            }
        }
        else if let n = obj["flood"] as? Int { out(String(repeating: "x", count: n)) }
        else if let h = obj["hook"] { runHook(h) }
        else if let call = obj["tool"], let data = try? JSONSerialization.data(withJSONObject: call),
                let value = try? JSONValue.parse(data) { runTool(value) }
        else if let h = obj["hookAsync"] {   // e.g. a permission left waiting
            Thread.detachNewThread { runHook(h) { p in asyncHooksLock.withLock { asyncHooks.append(p) } } }
        }
        else if obj["killHooks"] != nil { asyncHooksLock.withLock { asyncHooks.forEach { $0.terminate() } } }
        else if let label = obj["drain"] as? String {
            // Takes whatever input already arrived, without blocking; prints `label` if there was any.
            var p = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            while poll(&p, 1, 0) > 0, readStdin() {}
            if !input.isEmpty { out(label) }
        }
        else if let s = obj["sleep"] as? Double { usleep(UInt32(s * 1_000_000)) }
        else if let c = obj["exit"] as? Int { exit(Int32(c)) }
    }
}
while readStdin() {}
