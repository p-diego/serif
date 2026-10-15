import Foundation
import SerifCore

// Serif's tools for one bot (spec §4): an MCP server on stdin/stdout, started by the bot's agent. It keeps nothing:
// every call goes to the engine, as the bot the environment names.
let env = ProcessInfo.processInfo.environment

// ponytail: one call at a time, each waiting 10 s at most; a reader thread per call if agents ever call in parallel.
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let reply = mcpReply(to: Data(line.utf8), call: { forwardTool($0, $1, environment: env) })
    else { continue }
    print(reply)
    fflush(stdout)
}
