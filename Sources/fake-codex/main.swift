import Foundation

// Stands in for `codex` in the tests (never the real one): its checks, as the engine runs them before a launch (AgentCheck).
let env = ProcessInfo.processInfo.environment
switch Array(CommandLine.arguments.dropFirst()) {
case ["--version"]:
    print("codex-cli 0.160.0")
    exit(0)
case ["login", "status"]:
    // Like 0.160.0, the answer goes to standard error. Signed out while the file SERIF_FAKE_CODEX_LOGGED_OUT names exists.
    if let flag = env["SERIF_FAKE_CODEX_LOGGED_OUT"], FileManager.default.fileExists(atPath: flag) {
        FileHandle.standardError.write(Data("Not logged in\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("Logged in using ChatGPT\n".utf8))
    exit(0)
default:
    exit(2)
}
