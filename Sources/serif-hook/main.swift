import Foundation
import SerifCore

// Relays one Claude Code hook event (JSON on stdin) to the Serif engine and prints the
// engine's decision, if any. Every failure path exits 0 silently so a hook never breaks the bot.
let env = ProcessInfo.processInfo.environment
let input = FileHandle.standardInput.readDataToEndOfFile()

guard let socket = env["SERIF_HOOK_SOCKET"], let botId = env["SERIF_BOT_ID"], let token = env["SERIF_TOKEN"],
      let payload = try? JSONValue.parse(input),
      let line = try? protocolEncoder().encode(HookEnvelope(botId: botId, token: token, payload: payload))
else { exit(0) }

// Permission requests wait for the human as long as it takes; other events give up after 5 s.
let event = payload["hook_event_name"]?.string
let timeout: TimeInterval? = event == "PermissionRequest" ? nil : 5

if let data = LineClient.request(path: socket, line: line, timeout: timeout),
   let reply = try? protocolDecoder().decode(HookReply.self, from: data),
   let out = reply.stdout {
    FileHandle.standardOutput.write(Data((out + "\n").utf8))
}
exit(0)
