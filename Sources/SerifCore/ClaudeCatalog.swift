import Foundation

/// A skill or plugin of the user's Claude Code that a bot or a project can be given (spec §6.3).
public struct CatalogItem: Codable, Equatable, Identifiable, Sendable {
    /// What is saved: a skill's folder path; a plugin's id ("name@marketplace" when installed, "name" when synced).
    public let id: String
    public let name: String
    public let description: String
    /// The skill's folder (with SKILL.md) or the plugin's (passed to --plugin-dir).
    public let path: String

    public init(id: String, name: String, description: String, path: String) {
        self.id = id; self.name = name; self.description = description; self.path = path
    }
}

/// Claude Code's configuration folder: `CLAUDE_CONFIG_DIR` when set (as Claude Code reads it), else `~/.claude`.
public func claudeConfigRoot(environment: [String: String]) -> URL {
    if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
}

/// The user's skills and plugins, read from Claude Code's folder. Anything missing or unreadable is simply absent
/// (spec §9: then only "From a folder…" is left).
public struct ClaudeCatalog: Equatable, Sendable {
    public var skills: [CatalogItem] = []
    public var plugins: [CatalogItem] = []

    public init() {}
    public init(root: URL) {
        skills = Self.skills(root: root)
        plugins = Self.plugins(root: root)
    }

    /// Every folder with a SKILL.md under `<root>/skills`: the user's own and those synced from claude.ai
    /// (`synced/<account>/<name>`). Name and description come from the SKILL.md front matter, else the folder name.
    /// A linked `skills` folder (or config root) is read where it leads (the enumerator would not enter the link), but
    /// paths are reported under the unresolved `<root>/skills`, so ids saved earlier keep matching.
    public static func skills(root: URL) -> [CatalogItem] {
        let shown = root.appendingPathComponent("skills").path
        let resolved = root.appendingPathComponent("skills").resolvingSymlinksInPath().path
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: resolved),
                                                        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var items: [CatalogItem] = []
        for case let url as URL in walk {
            guard let text = try? String(contentsOf: url.appendingPathComponent("SKILL.md"), encoding: .utf8) else { continue }
            walk.skipDescendants()          // a skill's own files are not skills
            let header = frontMatter(text)
            // Normalise the same way as `resolved` (it drops a leading /private, the enumerator's paths keep it).
            let real = url.resolvingSymlinksInPath().path
            let path = real.hasPrefix(resolved) ? shown + real.dropFirst(resolved.count) : url.path
            items.append(CatalogItem(id: path, name: header["name"] ?? url.lastPathComponent,
                                     description: header["description"] ?? "", path: path))
        }
        return sorted(items)
    }

    /// Installed plugins (`plugins/installed_plugins.json`: id → installs, the first one's `installPath`) and those synced
    /// from claude.ai (`plugins/synced/<account>/<name>[~gN]`, only the highest N of each name). Name and description come
    /// from `.claude-plugin/plugin.json`. A plugin whose folder is gone is left out.
    public static func plugins(root: URL) -> [CatalogItem] {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("plugins")
        var items: [CatalogItem] = []
        if let data = try? Data(contentsOf: dir.appendingPathComponent("installed_plugins.json")),
           let installed = (try? JSONValue.parse(data))?["plugins"]?.object {
            for (id, installs) in installed {
                if let folder = installs.array?.first?["installPath"]?.string, let item = plugin(id: id, folder: folder) {
                    items.append(item)
                }
            }
        }
        var synced: [String: (generation: Int, folder: String)] = [:]
        let syncedDir = dir.appendingPathComponent("synced")
        for account in (try? fm.contentsOfDirectory(atPath: syncedDir.path)) ?? [] where !account.hasPrefix(".") {
            let accountDir = syncedDir.appendingPathComponent(account)
            for entry in (try? fm.contentsOfDirectory(atPath: accountDir.path)) ?? [] {
                let folder = accountDir.appendingPathComponent(entry).path
                guard fm.fileExists(atPath: folder + "/.claude-plugin/plugin.json") else { continue }    // e.g. *.meta.json
                let (name, generation) = syncedName(entry)
                if let known = synced[name], known.generation >= generation { continue }
                synced[name] = (generation, folder)
            }
        }
        for (name, newest) in synced { if let item = plugin(id: name, folder: newest.folder) { items.append(item) } }
        return sorted(items)
    }

    /// By name, then id: two plugins named alike (installed "figma@…" and synced "figma") keep one order.
    private static func sorted(_ items: [CatalogItem]) -> [CatalogItem] {
        items.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// The folders of the plugins `ids` names, in order and each once (a plugin chosen for both the bot and its project
    /// counts once), and the ids not in `plugins`: left out of the launch (spec §6.2–6.3).
    public static func pluginFolders(_ ids: [String], in plugins: [CatalogItem]) -> (folders: [String], missing: [String]) {
        var folders: [String] = [], missing: [String] = []
        for id in ids {
            guard let folder = plugins.first(where: { $0.id == id })?.path else {
                if !missing.contains(id) { missing.append(id) }
                continue
            }
            if !folders.contains(folder) { folders.append(folder) }
        }
        return (folders, missing)
    }

    /// "figma~g2" → ("figma", 2); a folder without the suffix is generation 0.
    static func syncedName(_ folder: String) -> (name: String, generation: Int) {
        if let r = folder.range(of: "~g", options: .backwards), let n = Int(folder[r.upperBound...]) {
            return (String(folder[..<r.lowerBound]), n)
        }
        return (folder, 0)
    }

    private static func plugin(id: String, folder: String) -> CatalogItem? {
        guard FileManager.default.fileExists(atPath: folder) else { return nil }
        let manifest = (try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(".claude-plugin/plugin.json")))
            .flatMap { try? JSONValue.parse($0) }
        let name = manifest?["name"]?.string ?? String(id.split(separator: "@").first ?? Substring(id))
        return CatalogItem(id: id, name: name, description: manifest?["description"]?.string ?? "", path: folder)
    }

    /// The top-level keys of a SKILL.md's YAML front matter (between the first two `---` lines): one-line values, quotes
    /// dropped; a `>` or `|` block takes the indented lines under it, joined by spaces. Empty values are left out.
    static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            i += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-", ""].contains(value) {
                var block: [String] = []
                while i < lines.count, lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") {
                    block.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                value = block.joined(separator: " ")
            } else if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { out[key] = value }
        }
        return out
    }
}
