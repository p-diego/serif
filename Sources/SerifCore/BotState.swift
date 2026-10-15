import Foundation

/// The engine's view of a bot's lifecycle, as shown in the app.
public enum BotState: Codable, Equatable, Sendable {
    case starting, ready
    case working(Activity)
    case waiting(kind: WaitKind, requestId: UUID)
    case rateLimited(until: Date?)
    case crashed(reason: String, retryAt: Date?)
    case stopped
}

extension BotState {
    /// A turn is running: working, or waiting on a request.
    public var inTurn: Bool {
        switch self { case .working, .waiting: true; default: false }
    }
}

/// Tracks a bot's `BotState` from process and chat events.
public struct StateTracker: Sendable {
    public private(set) var state: BotState = .starting
    /// Requests still open, oldest first: while any is open the bot waits on the oldest, whatever else Claude Code says.
    private var open: [(id: UUID, kind: WaitKind)] = []

    public init() {}

    public mutating func processStarted() {
        open = []
        state = .starting
    }

    /// Only moves a freshly started, crashed or stopped bot to `.ready`; a bot already busy keeps its state.
    public mutating func sessionStarted() {
        switch state {
        case .starting, .crashed, .stopped: state = .ready
        default: break
        }
    }

    public mutating func processExited(reason: String, retryAt: Date?) {
        open = []
        state = .crashed(reason: reason, retryAt: retryAt)
    }

    public mutating func stopped() {
        open = []
        state = .stopped
    }

    public mutating func rateLimited(until: Date?) {
        state = .rateLimited(until: until)
    }

    /// While rate limited, only a new user message moves the bot on.
    public mutating func apply(_ event: ChatEvent) {
        if case .rateLimited = state {
            guard case .userMessage = event else { return }
        }
        switch event {
        case .userMessage:
            state = .working(.thinking)
        case .assistantText:
            state = .working(.typing)
        case let .toolStarted(_, name, input, _):
            state = .working(Activity.from(toolName: name, input: input))
        case .toolFinished:
            // A Codex command left running when its turn ended closes later (spec §3.3): the bot stays ready.
            if state.inTurn { state = .working(.thinking) }
        case let .requestOpened(request):
            // A decision card never holds the bot (spec §6 of 0.6): it goes on, the answer comes later as mail.
            if request.kind != .decision { open.append((request.id, request.kind)) }
        case let .requestClosed(requestId, _, _):
            guard let i = open.firstIndex(where: { $0.id == requestId }) else { break }
            open.remove(at: i)
            if open.isEmpty { state = .working(.thinking) }
        case .turnEnded, .turnFailed, .turnInterrupted:
            open = []
            state = .ready
        case .assistantTextReplaced, .subagent, .system, .mail, .task, .routineRun:
            break
        }
        if let oldest = open.first { state = .waiting(kind: oldest.kind, requestId: oldest.id) }
    }
}

/// True if a turn ended (normally, failed or interrupted) after the last read sequence number, unless the mail started
/// it (spec §6 of 0.5): `records` from the turn's start on.
public func isUnread(lastReadSeq: Int, records: [ChatEventRecord]) -> Bool {
    var origin: MessageOrigin?
    return records.contains { record in
        if case let .userMessage(_, _, o, _) = record.event { origin = o }
        guard record.seq > lastReadSeq, origin != .bot else { return false }
        switch record.event {
        case .turnEnded, .turnFailed, .turnInterrupted: return true
        default: return false
        }
    }
}
