import Foundation
import SerifCore

public enum ClaudeLocator {
    /// Order: `override` (if executable) -> well-known install paths -> an interactive login zsh
    /// (`-ilc`: ~/.zshrc is where ~/.local/bin usually gets onto PATH, and launchd gives no PATH).
    public static func find(override: String?) -> String? {
        find(override: override, home: NSHomeDirectory(),
             isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }, shell: shellLookup)
    }

    static func find(override: String?, home: String, isExecutable: (String) -> Bool, shell: () -> String?) -> String? {
        if let o = override, !o.isEmpty, isExecutable(o) { return o }
        let candidates = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let c = candidates.first(where: isExecutable) { return c }
        if let s = shell(), s.hasPrefix("/"), isExecutable(s) { return s }
        return nil
    }

    private static func shellLookup() -> String? { LoginShell.run("command -v claude") }
}

public enum LoginShell {
    /// The last non-empty output line of `command` in an interactive login zsh (`-ilc`: ~/.zshrc is where PATH usually
    /// grows), or nil after 5 s. launchd starts the engine with a bare environment; this is the user's.
    public static func run(_ command: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", command]
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timeout.cancel()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}

/// Claude Code as the engine checks it before launching bots (spec §4): `claude --version` and `claude auth status`, run
/// with the bots' environment. A command that does not answer within 10 s leaves its field unknown (spec §9).
enum ClaudeCheck {
    static func status(path: String?, environment: [String: String]) -> ClaudeStatus {
        guard let path, FileManager.default.isExecutableFile(atPath: path) else {
            return ClaudeStatus(path: nil, version: nil, loggedIn: nil, email: nil)
        }
        let version = output(path, ["--version"], environment).flatMap(claudeVersion)
        let auth = output(path, ["auth", "status"], environment).map(claudeAuth)
        return ClaudeStatus(path: path, version: version, loggedIn: auth?.loggedIn, email: auth?.email)
    }

    /// Standard output of `executable args`, whatever its exit code (`auth status` exits 1 when signed out); nil if it cannot
    /// start or is still running after `timeout` seconds (it is then terminated).
    static func output(_ executable: String, _ args: [String], _ environment: [String: String],
                       timeout: TimeInterval = 10) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return p.terminationReason == .exit ? String(decoding: data, as: UTF8.self) : nil
    }
}
