import Foundation
import SerifCore
import SerifEngine

// The Serif engine daemon, started by launchd (or by hand in development).
var env = ProcessInfo.processInfo.environment
// launchd's PATH is /usr/bin:/bin:/usr/sbin:/sbin: bots get the login shell's, or they miss Homebrew and the user's tools.
if let path = LoginShell.run("printf '%s\\n' \"$PATH\""), path.hasPrefix("/") { env["PATH"] = path }
// serif-hook sits next to serifd: Serif.app/Contents/MacOS in the bundle, the build folder in development.
let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
let hookCommand = executable.deletingLastPathComponent().appendingPathComponent("serif-hook").path

// launchd throws stderr away: the reason also goes to serifd.log in the data folder.
func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("serifd: \(error)\n".utf8))
    Engine.log("start-up failed: \(error)", to: .standard())
    exit(1)
}

let overrides: [Agent: String] = [.claude: env["SERIF_CLAUDE"], .codex: env["SERIF_CODEX"]].compactMapValues { $0 }
let engine: Engine
do {
    // An agent is looked for when its first bot launches, and again while it is missing (it may be installed later) or
    // gone from where it was; it is checked again after one of its bots crashes.
    engine = try Engine(paths: .standard(), locate: { AgentLocator.find($0, override: overrides[$0]) },
                        hookCommand: hookCommand, environment: env)
} catch { fail(error) }

// Ready for SIGTERM before any bot starts. A no-op handler, not SIG_IGN: an ignored signal stays ignored across exec,
// so every bot would ignore SIGTERM too; a caught one goes back to the default in the child. The source does the work.
signal(SIGTERM) { _ in }
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { engine.shutdown { exit(0) } }
sigterm.resume()

do {
    try engine.start()
} catch EngineError.alreadyRunning {
    exit(0)        // another engine owns this data folder: nothing to do
} catch { fail(error) }

dispatchMain()
