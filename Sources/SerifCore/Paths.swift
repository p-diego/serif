import Foundation

/// Locations of Serif's data folder and the files and sockets inside it.
public struct SerifPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `SERIF_HOME` when set, otherwise `~/Library/Application Support/Serif`.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> SerifPaths {
        if let home = environment["SERIF_HOME"], !home.isEmpty {
            return SerifPaths(root: URL(fileURLWithPath: home))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SerifPaths(root: support.appendingPathComponent("Serif"))
    }

    public var stateFile: URL { root.appendingPathComponent("state.json") }
    public var engineSocket: URL { root.appendingPathComponent("serifd.sock") }
    public var hookSocket: URL { root.appendingPathComponent("hook.sock") }
    public var log: URL { root.appendingPathComponent("serifd.log") }
    public var lock: URL { root.appendingPathComponent("serifd.lock") }

    /// Folder shared by every bot of one project.
    public func shared(_ project: UUID) -> URL {
        root.appendingPathComponent("projects").appendingPathComponent(project.uuidString).appendingPathComponent("shared")
    }

    /// A project's mail (spec §5 of 0.5): next to its shared folder, never inside it (bots write there).
    public func mail(_ project: UUID) -> URL {
        shared(project).deletingLastPathComponent().appendingPathComponent("mail.json")
    }

    public func bot(_ id: UUID) -> BotPaths {
        BotPaths(dir: root.appendingPathComponent("bots").appendingPathComponent(id.uuidString))
    }
}

/// Files that belong to one bot.
public struct BotPaths: Sendable {
    public let dir: URL

    public init(dir: URL) {
        self.dir = dir
    }

    public var workspace: URL { dir.appendingPathComponent("workspace") }
    public var systemPrompt: URL { dir.appendingPathComponent("system.md") }
    public var settings: URL { dir.appendingPathComponent("settings.json") }
    public var mcpConfig: URL { dir.appendingPathComponent("mcp.json") }
    public var events: URL { dir.appendingPathComponent("events.jsonl") }
    public var meta: URL { dir.appendingPathComponent("meta.json") }
}
