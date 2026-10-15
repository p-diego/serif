import Foundation

/// Time shown on a sidebar row: "HH:mm" today, `yesterday` (localized by the caller), the weekday (current locale) within
/// the last 6 days, otherwise "d/M/yy".
public func rowTime(_ date: Date, now: Date, calendar: Calendar, yesterday: String) -> String {
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    func format(_ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = calendar.locale ?? .current
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
    switch days {
    case ..<1: return format("HH:mm")
    case 1: return yesterday
    case 2...6: return format("EEEE")
    default: return format("d/M/yy")
    }
}

/// Mascot mood for a bot's state; an unread reply on a ready bot reads as "done".
public func mood(for state: BotState, unread: Bool) -> MascotMood {
    switch state {
    case .working: .work
    case .waiting: .wait
    case .crashed, .rateLimited: .alarm
    case .starting, .stopped: .sleep
    case .ready: unread ? .done : .watch
    }
}

/// What a sidebar row says under the name; the app turns it into localized text.
public enum RowPreview: Equatable, Sendable {
    case typing
    case waiting(String?)    // the request summary, if known
    case crashed(String)
    case rateLimited
    case text(String)
    case mail(MailNote)      // the last thing that happened was mail (spec §6)
}

public func rowPreview(_ summary: BotSummary) -> RowPreview {
    switch summary.state {
    case .working: .typing
    case .waiting: .waiting(summary.preview)
    case .crashed(let reason, _): .crashed(reason)
    case .rateLimited: .rateLimited
    default:
        if case let .mail(note)? = summary.lastEvent?.event { .mail(note) }
        else { .text(plainText(markdown: summary.preview ?? "")) }
    }
}

/// A reply's Markdown as plain text, for one-line previews and notifications ("**Title**" reads "Title").
public func plainText(markdown: String) -> String {
    guard let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    else { return markdown }
    return String(attributed.characters)
}

/// What a group of steps is about (by majority); the app turns it into a card title.
public enum StepsKind: Hashable, Sendable {
    case commands, files, search, web
    case mixed(String)    // a tool without its own kind: its name
}

public struct StepsCounts: Equatable, Sendable {
    public var commands = 0, filesRead = 0, filesEdited = 0, searches = 0, other = 0
    public init(commands: Int = 0, filesRead: Int = 0, filesEdited: Int = 0, searches: Int = 0, other: Int = 0) {
        self.commands = commands; self.filesRead = filesRead; self.filesEdited = filesEdited
        self.searches = searches; self.other = other
    }
}

private func category(_ tool: String) -> StepsKind? {
    switch tool {
    case "Bash": .commands
    case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit": .files
    case "Grep", "Glob": .search
    case "WebSearch", "WebFetch": .web
    default: nil
    }
}

public func stepsCounts(_ steps: [Step]) -> StepsCounts {
    var c = StepsCounts()
    for s in steps {
        switch s.name {
        case "Bash": c.commands += 1
        case "Read": c.filesRead += 1
        case "Edit", "Write", "MultiEdit", "NotebookEdit": c.filesEdited += 1
        case "Grep", "Glob": c.searches += 1
        default: c.other += 1
        }
    }
    return c
}

/// The kind with the most steps; a tie goes to the one that appears first. Unknown tools count by name (`.mixed(name)`).
public func stepsKind(_ steps: [Step]) -> StepsKind {
    var counts: [StepsKind: Int] = [:]
    var order: [StepsKind] = []
    for s in steps {
        let k = category(s.name) ?? .mixed(s.name)
        if counts[k] == nil { order.append(k) }
        counts[k, default: 0] += 1
    }
    var best: StepsKind = .mixed("")
    var bestCount = 0
    for k in order where counts[k]! > bestCount { best = k; bestCount = counts[k]! }
    return best
}

/// What a pending request asks, for the sidebar row; the app turns it into localized text.
public enum RequestSummary: Equatable, Sendable {
    case command(String)
    case file(String)         // file name (last path component) a write or edit targets
    case question(String)
    case plan
    case tool(String)         // anything else: the tool's name
}

public func requestSummary(_ r: PendingRequest) -> RequestSummary {
    switch r.kind {
    case .plan: return .plan
    case .question:
        if let q = r.input["questions"]?.array?.first?["question"]?.string { return .question(q) }
    case .permission:
        if r.toolName == "Bash", let c = r.input["command"]?.string { return .command(c) }
        if let p = r.input["file_path"]?.string, ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(r.toolName) {
            return .file(URL(fileURLWithPath: p).lastPathComponent)
        }
    }
    return .tool(r.toolName)
}

/// Out-of-window signals; the app turns each into a localized notification.
public enum NotificationKind: Equatable, Sendable { case waiting, finished, failed, rateLimited }

/// Whether a chat event deserves a notification: never for muted bots, never while the user looks at that bot's chat,
/// never "finished" for a turn the mail started (`turnOrigin`, spec §6 of 0.5); cards and errors always.
public func shouldNotify(event: ChatEvent, bot: Bot, viewingBot: UUID?, windowKey: Bool,
                         turnOrigin: MessageOrigin? = nil) -> NotificationKind? {
    guard bot.notifications, !(viewingBot == bot.id && windowKey) else { return nil }
    switch event {
    case .requestOpened: return .waiting
    case .turnEnded: return turnOrigin == .bot ? nil : .finished
    case .turnFailed(let reason):
        let r = reason.lowercased()
        return r.contains("rate_limit") || r.contains("rate limit") ? .rateLimited : .failed
    case .system(.crashed): return .failed      // the bot's process died (spec §4.7: errors notify)
    default: return nil
    }
}
