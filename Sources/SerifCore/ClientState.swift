import Foundation

/// What the app knows about the engine's world. A pure reducer: the engine client feeds it snapshots and pushes.
public struct ClientState: Equatable, Sendable {
    public var connected = false
    public var projects: [Project] = []
    public var bots: [UUID: BotSummary] = [:]
    public var requests: [UUID: PendingRequest] = [:]
    /// Each project's routines (spec §4 of 0.6).
    public var routines: [UUID: [Routine]] = [:]
    public var transcripts: [UUID: Transcript] = [:]
    /// Sent from the app, not yet taken by the engine (shown as translucent bubbles).
    public var pendingSends: [UUID: [String]] = [:]

    public init() {}

    public mutating func apply(snapshot: Snapshot) {
        connected = true
        projects = snapshot.projects
        bots = Dictionary(snapshot.bots.map { ($0.bot.id, $0) }, uniquingKeysWith: { _, new in new })
        requests = Dictionary(snapshot.requests.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        routines = Dictionary(grouping: snapshot.routines) { bots[$0.botId]?.bot.projectId ?? UUID() }
    }

    public mutating func apply(_ push: Push) {
        switch push {
        case .botChanged(let summary):
            bots[summary.bot.id] = summary
        case .projectChanged(let project):
            if let i = projects.firstIndex(where: { $0.id == project.id }) { projects[i] = project } else { projects.append(project) }
        case .chatEvent(let botId, let record):
            // History is loaded on demand: without a transcript only the row preview changes.
            transcripts[botId]?.apply(record)
            bots[botId]?.lastEvent = record
            // Trimmed on both sides, like the normalizer's own chat-origin match.
            if case .userMessage(let text, _, .chat) = record.event {
                let taken = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let i = pendingSends[botId]?.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == taken }) {
                    pendingSends[botId]?.remove(at: i)
                }
            }
        case .requestOpened(let request):
            requests[request.id] = request
        case .requestClosed(let id, _, _, _):
            requests[id] = nil
        case .terminalOutput:
            break    // the terminal view reads these directly
        case .routinesChanged(let projectId, let list):
            routines[projectId] = list
        }
    }

    /// A bot's routines, by name.
    public func routines(of bot: UUID) -> [Routine] {
        (bots[bot].flatMap { routines[$0.bot.projectId] } ?? []).filter { $0.botId == bot }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The cards open for you, of every live bot, oldest first: the "waiting for you" row and view (spec §7 of 0.6).
    public var waitingForYou: [PendingRequest] {
        requests.values.filter { bots[$0.botId]?.bot.archivedAt == nil }.sorted { $0.openedAt < $1.openedAt }
    }

    /// Before asking for a bot's history: chat events pushed while it loads land in this transcript instead of being lost.
    public mutating func historyRequested(bot: UUID) {
        if transcripts[bot] == nil { transcripts[bot] = Transcript() }
    }

    /// A page of history, merged under what is already there (deduplicated by seq).
    public mutating func historyLoaded(_ records: [ChatEventRecord], bot: UUID) {
        transcripts[bot, default: Transcript()].prepend(records)
    }

    /// Keeps the data on screen while the app reconnects.
    public mutating func disconnected() { connected = false }

    /// Bots waiting for the user (Dock badge).
    public var waitingCount: Int {
        bots.values.filter { $0.bot.archivedAt == nil && { if case .waiting = $0.state { true } else { false } }($0) }.count
    }

    /// Non-archived projects in creation order, each with its live bots, newest activity first.
    /// A search keeps bots whose name matches, or all bots of a project whose name matches.
    public func sections(search: String) -> [(project: Project, bots: [BotSummary])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return projects.filter { $0.archivedAt == nil }.sorted { $0.createdAt < $1.createdAt }.compactMap { project in
            var list = bots.values.filter { $0.bot.projectId == project.id && $0.bot.archivedAt == nil }
                .sorted(by: Self.newestFirst)
            if !query.isEmpty && !project.name.localizedCaseInsensitiveContains(query) {
                list = list.filter { $0.bot.name.localizedCaseInsensitiveContains(query) }
                if list.isEmpty { return nil }
            } else if !query.isEmpty && list.isEmpty {
                return nil
            }
            return (project, list)
        }
    }

    public var pinned: [BotSummary] {
        bots.values.filter { $0.bot.pinned && $0.bot.archivedAt == nil }
            .sorted(by: Self.newestFirst)
    }

    /// Newest activity first; equal dates fall back to name, then id, so the order never flickers.
    private static func newestFirst(_ a: BotSummary, _ b: BotSummary) -> Bool {
        let (x, y) = (activity(a), activity(b))
        if x != y { return x > y }
        if a.bot.name != b.bot.name { return a.bot.name < b.bot.name }
        return a.bot.id.uuidString < b.bot.id.uuidString
    }

    private static func activity(_ s: BotSummary) -> Date { s.lastEvent?.at ?? s.bot.createdAt }
}
