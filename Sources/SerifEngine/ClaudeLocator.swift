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
        ClaudeCheck.output("/bin/zsh", ["-ilc", command], ProcessInfo.processInfo.environment, timeout: 5)?
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
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
    /// start or does not finish within `timeout` seconds (it is then killed), even if a grandchild keeps its output open.
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
