import Foundation
import SerifCore

/// Per-bot counters persisted in `meta.json`.
public struct BotMeta: Codable, Equatable, Sendable {
    public var lastReadSeq: Int = 0
    public var lastSeq: Int = 0
    public var crashCount: Int = 0
    /// True after the first SessionStart (the next launch uses --resume).
    public var hasStarted: Bool = false
    public init() {}
}

/// Persists projects, bots and every chat event under the Serif data folder.
/// Not thread-safe: the engine calls it from one serial queue.
public final class Store {
    private struct State: Codable { var projects: [Project]; var bots: [Bot] }

    private let paths: SerifPaths
    private let encoder = protocolEncoder()
    private let decoder = protocolDecoder()
    private var metas: [UUID: BotMeta] = [:]
    private var mailboxes: [UUID: Mailbox] = [:]
    private var routineLists: [UUID: [Routine]] = [:]
    public private(set) var projects: [Project] = []
    public private(set) var bots: [Bot] = []

    public init(paths: SerifPaths) throws {
        self.paths = paths
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        // Only a missing file means "empty"; any other read error must not lead to overwriting real state.
        if FileManager.default.fileExists(atPath: paths.stateFile.path) {
            let data = try Data(contentsOf: paths.stateFile)
            let state = try decoder.decode(State.self, from: data)
            projects = state.projects
            bots = state.bots
        }
    }

    public func save(project: Project) throws {
        if let i = projects.firstIndex(where: { $0.id == project.id }) { projects[i] = project } else { projects.append(project) }
        try writeState()
    }

    public func save(bot: Bot) throws {
        if let i = bots.firstIndex(where: { $0.id == bot.id }) { bots[i] = bot } else { bots.append(bot) }
        try writeState()
    }

    public func meta(_ bot: UUID) -> BotMeta {
        if let cached = metas[bot] { return cached }
        var meta = (try? Data(contentsOf: paths.bot(bot).meta)).flatMap { try? decoder.decode(BotMeta.self, from: $0) } ?? BotMeta()
        // Meta missing or behind the event file (crash between the two writes): trust the file.
        if let top = (try? readAll(bot))?.last?.seq, top > meta.lastSeq { meta.lastSeq = top }
        metas[bot] = meta
        return meta
    }

    public func setMeta(_ meta: BotMeta, for bot: UUID) throws {
        metas[bot] = meta
        try writeAtomically(try encoder.encode(meta), to: paths.bot(bot).meta)
    }

    public func append(_ event: ChatEvent, bot: UUID, at: Date) throws -> ChatEventRecord {
        var meta = self.meta(bot)
        let record = ChatEventRecord(seq: meta.lastSeq + 1, at: at, event: event)
        try appendLine(try encoder.encode(record), to: paths.bot(bot).events)
        meta.lastSeq = record.seq
        try setMeta(meta, for: bot)
        return record
    }

    /// A change of the bot, one more line of its `history.jsonl` (spec §5 of 0.7).
    public func append(_ change: BotChange, bot: UUID) throws {
        try appendLine(try encoder.encode(change), to: paths.bot(bot).history)
    }

    /// The bot's last `limit` changes, oldest first; a line that cannot be read is skipped, like the chat's (spec §10).
    public func changes(bot: UUID, limit: Int = 200) -> [BotChange] {
        guard let data = try? Data(contentsOf: paths.bot(bot).history) else { return [] }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        return Array(lines.compactMap { try? decoder.decode(BotChange.self, from: Data($0)) }.suffix(limit))
    }

    /// One JSON line at the end of `url` (the chat, the history), the file made if missing.
    private func appendLine(_ json: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var line = json + Data("\n".utf8)
        // A crash can leave a last line without newline: start a fresh line so the new record stays readable.
        if size > 0 {
            try handle.seek(toOffset: size - 1)
            if try handle.read(upToCount: 1)?.first != UInt8(ascii: "\n") { line.insert(UInt8(ascii: "\n"), at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
    }

    /// Ascending; the newest `limit` records with seq < `beforeSeq` (all when nil).
    public func history(bot: UUID, beforeSeq: Int?, limit: Int) throws -> [ChatEventRecord] {
        let all = try readAll(bot).filter { beforeSeq == nil || $0.seq < beforeSeq! }
        return Array(all.suffix(max(limit, 0)))
    }

    public func records(bot: UUID, afterSeq: Int) throws -> [ChatEventRecord] {
        try readAll(bot).filter { $0.seq > afterSeq }
    }

    /// A project's mail (spec §5), read once: empty when there is none. A file that cannot be read is kept as
    /// `mail.json.bad` and the mail starts empty (spec §10), with a line in the log.
    public func mailbox(_ project: UUID) -> Mailbox {
        if let cached = mailboxes[project] { return cached }
        let mailbox = read(Mailbox.self, at: paths.mail(project), of: project) ?? Mailbox()
        mailboxes[project] = mailbox
        return mailbox
    }

    /// Written whole and atomically at every change, like `state.json` (spec §5).
    public func save(_ mailbox: Mailbox, project: UUID) throws {
        try writeAtomically(try encoder.encode(mailbox), to: paths.mail(project))
        mailboxes[project] = mailbox            // after the write: a failed save leaves memory as the disk is
    }

    /// The engine's own moves keep their change in memory when the write failed, so nothing repeats; the next
    /// successful save writes it (a restart before that may redo one delivery).
    public func keep(_ mailbox: Mailbox, project: UUID) { mailboxes[project] = mailbox }

    /// A project's routines (spec §4 of 0.6), kept like its mail: read once, a bad file set aside as `routines.json.bad`.
    public func routines(_ project: UUID) -> [Routine] {
        if let cached = routineLists[project] { return cached }
        let routines = read([Routine].self, at: paths.routines(project), of: project) ?? []
        routineLists[project] = routines
        return routines
    }

    /// Written whole and atomically like the mail; memory changes only once the write worked.
    public func save(_ routines: [Routine], project: UUID) throws {
        try writeAtomically(try encoder.encode(routines), to: paths.routines(project))
        routineLists[project] = routines
    }

    /// The engine's own moves keep their change in memory when the write failed, as for the mail.
    public func keep(_ routines: [Routine], project: UUID) { routineLists[project] = routines }

    /// A project file that decodes; nil when there is none. One that cannot be read is kept as `<name>.bad` and the
    /// project starts without it (spec §10 of 0.5, §9 of 0.6), with a line in the log.
    private func read<T: Decodable>(_ type: T.Type, at url: URL, of project: UUID) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let data = try? Data(contentsOf: url), let value = try? decoder.decode(type, from: data) { return value }
        let bad = url.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
        Engine.log("\(url.lastPathComponent) of project \(project) unreadable: kept as \(bad.lastPathComponent), starting empty",
                   to: paths)
        return nil
    }

    public func prepareFolders(for bot: Bot) throws {
        try FileManager.default.createDirectory(at: paths.bot(bot.id).workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.shared(bot.projectId), withIntermediateDirectories: true)
    }

    // ponytail: every read parses the whole file; add a seq index or tail-seek if chats get huge.
    private func readAll(_ bot: UUID) throws -> [ChatEventRecord] {
        guard let data = try? Data(contentsOf: paths.bot(bot).events) else { return [] }
        // Truncated or corrupt lines (crash mid-write) are skipped.
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(ChatEventRecord.self, from: Data($0)) }
    }

    private func writeState() throws {
        try writeAtomically(try encoder.encode(State(projects: projects, bots: bots)), to: paths.stateFile)
    }

    /// Temp file in the same folder, then rename over the target.
    private func writeAtomically(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do { try data.write(to: tmp) } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        if rename(tmp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
