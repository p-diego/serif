import Foundation
import SerifCore

public enum AgentLocator {
    /// The ChatGPT app's own Codex CLI (spec §3.1), updated with the app.
    static let chatGPTCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

    /// Claude Code: `override` (if executable) -> well-known install paths -> an interactive login zsh (`-ilc`: ~/.zshrc is
    /// where ~/.local/bin usually gets onto PATH, and launchd gives no PATH). Codex: `override` -> the login shell (a Codex
    /// the user installed) -> the ChatGPT app's copy.
    public static func find(_ agent: Agent, override: String?) -> String? {
        find(agent, override: override, home: NSHomeDirectory(), isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
             shell: { LoginShell.run("command -v \(agent.rawValue)") })
    }

    static func find(_ agent: Agent, override: String?, home: String, isExecutable: (String) -> Bool, shell: () -> String?) -> String? {
        if let o = override, !o.isEmpty, isExecutable(o) { return o }
        func fromShell() -> String? { shell().flatMap { $0.hasPrefix("/") && isExecutable($0) ? $0 : nil } }
        switch agent {
        case .claude:
            return [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].first(where: isExecutable) ?? fromShell()
        case .codex:
            return fromShell() ?? (isExecutable(chatGPTCodex) ? chatGPTCodex : nil)
        }
    }
}

public enum LoginShell {
    /// The last non-empty output line of `command` in an interactive login zsh (`-ilc`: ~/.zshrc is where PATH usually
    /// grows), or nil after 5 s. launchd starts the engine with a bare environment; this is the user's.
    public static func run(_ command: String) -> String? {
        AgentCheck.output("/bin/zsh", ["-ilc", command], ProcessInfo.processInfo.environment, timeout: 5)?
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}

/// An agent as the engine checks it before launching its bots (spec §4 of 0.3, §8): its version and sign-in, run with the
/// bots' environment. A command that does not answer within 10 s leaves its field unknown.
enum AgentCheck {
    static func status(_ agent: Agent, path: String?, environment: [String: String]) -> AgentStatus {
        guard let path, FileManager.default.isExecutableFile(atPath: path) else {
            return AgentStatus(agent: agent, path: nil, version: nil, loggedIn: nil, email: nil)
        }
        switch agent {
        case .claude:
            let version = output(path, ["--version"], environment).flatMap(claudeVersion)
            let auth = output(path, ["auth", "status"], environment).map(claudeAuth)
            return AgentStatus(agent: .claude, path: path, version: version, loggedIn: auth?.loggedIn, email: auth?.email)
        case .codex:
            // `codex login status` answers on standard error (verified with 0.160.0).
            let version = output(path, ["--version"], environment).flatMap(codexVersion)
            let login = output(path, ["login", "status"], environment, readErrors: true).flatMap(codexLoggedIn)
            return AgentStatus(agent: .codex, path: path, version: version, loggedIn: login, email: nil)
        }
    }

    /// Standard output of `executable args` (with standard error too when `readErrors`), whatever its exit code (a signed-out
    /// check exits 1); nil if it cannot start or does not finish within `timeout` seconds (it is then killed), even if a
    /// grandchild keeps its output open.
    static func output(_ executable: String, _ args: [String], _ environment: [String: String],
                       timeout: TimeInterval = 10, readErrors: Bool = false) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = readErrors ? pipe : FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        var data = Data()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { data = pipe.fileHandleForReading.readDataToEndOfFile(); read.signal() }
        guard read.wait(timeout: .now() + timeout) == .success else {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return nil   // ponytail: a grandchild holding stdout keeps this one reader thread parked until it exits
        }
        p.waitUntilExit()
        return p.terminationReason == .exit ? String(decoding: data, as: UTF8.self) : nil
    }
}
