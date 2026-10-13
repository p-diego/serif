import Foundation

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
