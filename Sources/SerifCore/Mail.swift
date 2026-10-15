import Foundation

// Mail between the bots of a project (spec §5–6).

/// What a mail message is: a task, a reply about one, a note, or a notice of the engine's (spec §5).
/// At most this many active bots in a project when a BOT creates one (spec §7, author ruling 15/10, Gravity's number):
/// a runaway model cannot start dozens of agent processes. The user's own sheet has no cap.
public let maxBotsPerProject = 12

/// The error `create_bot` answers when the project is full, nil when there is room for one more.
public func createBotLimitError(activeBots: Int) -> String? {
    activeBots < maxBotsPerProject ? nil
        : "this project already has \(maxBotsPerProject) bots: ask the user to create more"
}

public enum MailKind: String, Codable, Sendable { case task, reply, note, system }

/// Where a task stands (spec §5); only an open one changes.
public enum TaskStatus: String, Codable, Sendable { case open, done, cancelled, expired }

/// What a message of the engine's says (spec §5–6): its English text for the bot and the app's line are both made from
/// it. `done` also marks the reply that closes a task.
public enum MailNotice: String, Codable, Sendable {
    case done, cancelledByRequester, cancelledByUser, cancelledArchived, expired
}

public enum MailDirection: String, Codable, Sendable { case sent, received }

/// A mail message in a bot's chat (spec §6): received (a bubble, or a line for a notice) or sent (a line). Names as
/// they were then; `from` nil is you (a decision's answer, spec §6 of 0.6).
public struct MailNote: Codable, Equatable, Sendable {
    public var messageId: UUID
    public var kind: MailKind
    public var from: String?
    public var to: String
    public var direction: MailDirection
    /// The body, the result or the reason; for a notice, its whole English text.
    public var text: String
    public var taskNumber: Int?
    public var notice: MailNotice?

    public init(messageId: UUID, kind: MailKind, from: String?, to: String, direction: MailDirection, text: String,
                taskNumber: Int? = nil, notice: MailNotice? = nil) {
        self.messageId = messageId; self.kind = kind; self.from = from; self.to = to; self.direction = direction
        self.text = text; self.taskNumber = taskNumber; self.notice = notice
    }
}

/// A task as both chats show it (spec §6), recorded again at every change of its status.
public struct TaskCard: Codable, Equatable, Sendable {
    public var number: Int
    public var from: String
    public var to: String
    public var text: String
    public var deadline: Date
    public var status: TaskStatus
    public var result: String?

    public init(number: Int, from: String, to: String, text: String, deadline: Date, status: TaskStatus,
                result: String? = nil) {
        self.number = number; self.from = from; self.to = to; self.text = text; self.deadline = deadline
        self.status = status; self.result = result
    }
}

/// A message in a project's mail (spec §5); `deliveredAt` stays nil until its bot has it (a turn, or `check_inbox`).
/// `from` nil is the user: the answer to a decision (spec §6 of 0.6).
public struct MailMessage: Codable, Equatable, Sendable {
    public var id: UUID
    public var from: UUID?
    public var to: UUID
    public var kind: MailKind
    /// The body (task, reply, note), the result (`done`), the reason (`cancelledByRequester`), else empty.
    public var text: String
    public var taskId: Int?
    public var notice: MailNotice?
    public var createdAt: Date
    public var deliveredAt: Date?
}

/// A task (spec §5), numbered in its project.
public struct MailTask: Codable, Equatable, Sendable {
    public var number: Int
    public var from: UUID
    public var to: UUID
    public var text: String
    public var deadline: Date
    public var status: TaskStatus
    public var result: String?
    public var closedAt: Date?
    /// The tasks above it: the one whose turn created it, that one's, and so on (spec §5).
    public var chain: [Int]
}

/// Where a decision stands (spec §6 of 0.6); only an open one changes.
public enum DecisionStatus: String, Codable, Sendable { case open, answered, withdrawn }

/// Your answer to a decision (spec §6 of 0.6): an option (its index), words, or both.
public struct DecisionAnswer: Codable, Equatable, Sendable {
    public var option: Int?
    public var text: String?
    public init(option: Int?, text: String?) { self.option = option; self.text = text }
}

/// A choice a bot left to you (spec §6 of 0.6), numbered in its project and kept in its mail; its card is the request
/// `requestId`, so a restart shows the same card again.
public struct Decision: Codable, Equatable, Sendable {
    public var number: Int
    public var botId: UUID
    public var question: String
    public var options: [String]
    /// The index of the option the bot recommends, if any.
    public var recommendation: Int?
    public var context: String?
    public var status: DecisionStatus
    public var answer: DecisionAnswer?
    public var answeredAt: Date?
    public var createdAt: Date
    public var requestId: UUID
    /// Why the bot withdrew it.
    public var reason: String?
}

/// Why a tool call cannot be done, as a sentence the bot reads (spec §4).
public struct MailError: Error, Equatable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

/// One project's mail, saved whole in `projects/<id>/mail.json` (spec §5). Each move checks the rules and adds the
/// messages it causes; the engine delivers them (spec §6).
public struct Mailbox: Codable, Equatable, Sendable {
    public static let maxOpenTasks = 3, maxChain = 4, maxBytes = 65_536, hours = 1...168, defaultHours = 24
    public static let maxOpenDecisions = 3, maxDecisionBytes = 4096, decisionOptions = 2...6, maxOptionLength = 200

    public private(set) var messages: [MailMessage] = []
    public private(set) var tasks: [MailTask] = []
    public private(set) var lastTask = 0           // the counter behind "#17"
    public private(set) var decisions: [Decision] = []
    public private(set) var lastDecision = 0       // the counter behind a decision's "#5"

    public init() {}

    // A mail.json from 0.5 has no decisions: a field added later starts empty, the file is never set aside for it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([MailMessage].self, forKey: .messages) ?? []
        tasks = try c.decodeIfPresent([MailTask].self, forKey: .tasks) ?? []
        lastTask = try c.decodeIfPresent(Int.self, forKey: .lastTask) ?? 0
        decisions = try c.decodeIfPresent([Decision].self, forKey: .decisions) ?? []
        lastDecision = try c.decodeIfPresent(Int.self, forKey: .lastDecision) ?? 0
    }

    public func task(_ number: Int) -> MailTask? { tasks.first { $0.number == number } }

    /// The messages waiting for `bot`, oldest first.
    public func waiting(for bot: UUID) -> [MailMessage] { messages.filter { $0.to == bot && $0.deliveredAt == nil } }

    /// The task's own message reached its recipient, who has its card from then on.
    public func delivered(task number: Int) -> Bool {
        messages.contains { $0.kind == .task && $0.taskId == number && $0.deliveredAt != nil }
    }

    public mutating func markDelivered(_ id: UUID, at now: Date) {
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].deliveredAt = now }
    }

    /// `send_message` with kind `task` (spec §5): at most 3 open tasks for the bot that asks; the task whose delivery
    /// started its turn (`turnTask`) passes its chain on, at most 4 long and with no requester in it as the recipient.
    public mutating func sendTask(from: UUID, to: UUID, text: String, hours: Int?, turnTask: Int?,
                                  at now: Date) throws -> MailTask {
        try Self.checkSize(text)
        let hours = hours ?? Self.defaultHours
        guard Self.hours.contains(hours) else { throw MailError("deadline_hours must be between 1 and 168") }
        guard tasks.filter({ $0.from == from && $0.status == .open }).count < Self.maxOpenTasks else {
            throw MailError("you already have \(Self.maxOpenTasks) open tasks: wait for one to finish, or cancel one")
        }
        let chain = turnTask.flatMap(task).map { $0.chain + [$0.number] } ?? []
        guard chain.count < Self.maxChain else {
            throw MailError("this task would make a chain of \(chain.count + 1) tasks (at most \(Self.maxChain)): "
                            + "do this part yourself")
        }
        if let loop = chain.compactMap(task).first(where: { $0.from == to }) {
            throw MailError("that bot asked for task #\(loop.number) higher in this chain: "
                            + "reply to it instead of passing work back")
        }
        lastTask += 1
        let new = MailTask(number: lastTask, from: from, to: to, text: text,
                           deadline: now.addingTimeInterval(Double(hours) * 3600), status: .open, chain: chain)
        tasks.append(new)
        post(from: from, to: to, kind: .task, text: text, task: new.number, at: now)
        return new
    }

    /// `send_message` with kind `reply` or `note` (spec §5): a reply names an open task between the two bots.
    @discardableResult
    public mutating func sendMessage(from: UUID, to: UUID, kind: MailKind, text: String, task number: Int?,
                                     at now: Date) throws -> MailMessage {
        try Self.checkSize(text)
        if kind == .reply {
            guard let number else { throw MailError("a reply needs task_id, the open task it is about") }
            guard let t = task(number), Set([t.from, t.to]) == Set([from, to]) else {
                throw MailError("task #\(number) is not between you and that bot")
            }
            guard t.status == .open else { throw MailError("task #\(number) is already \(t.status.rawValue)") }
        }
        return post(from: from, to: to, kind: kind, text: text, task: kind == .reply ? number : nil, at: now)
    }

    /// `complete_task` (spec §5): only its recipient, while it is open. The result goes to the requester and, as a
    /// notice, to the project's lead when the lead is neither of the two.
    public mutating func complete(_ number: Int, by bot: UUID, result: String, lead: UUID?,
                                  at now: Date) throws -> MailTask {
        try Self.checkSize(result)
        let i = try openTask(number)
        guard tasks[i].to == bot else {
            throw MailError("task #\(number) was not given to you: only its recipient completes it")
        }
        close(i, .done, result: result, at: now)
        post(from: bot, to: tasks[i].from, kind: .reply, text: result, task: number, notice: .done, at: now)
        if let lead, lead != tasks[i].from, lead != bot {
            post(from: bot, to: lead, kind: .system, text: result, task: number, notice: .done, at: now)
        }
        return tasks[i]
    }

    /// `cancel_task` by the bot that asked, or the user's Cancel (`by` nil) (spec §5): the recipient is told, and after
    /// the user's Cancel the requester too.
    public mutating func cancel(_ number: Int, by bot: UUID?, reason: String?, at now: Date) throws -> MailTask {
        if let reason { try Self.checkSize(reason) }
        let i = try openTask(number)
        if let bot, tasks[i].from != bot {
            throw MailError("only the bot that asked for task #\(number) can cancel it")
        }
        close(i, .cancelled, at: now)
        tellRecipient(tasks[i], bot == nil ? .cancelledByUser : .cancelledByRequester, text: reason ?? "", at: now)
        if bot == nil { tellRequester(tasks[i], .cancelledByUser, at: now) }
        return tasks[i]
    }

    /// The open tasks past their deadline expire and their requesters are told (spec §5). Messages delivered more than
    /// 8 days ago go too, unless their task is still open (after a long downtime its card must still be found).
    public mutating func expire(at now: Date) -> [MailTask] {
        let open = Set(tasks.filter { $0.status == .open }.map(\.number))
        messages.removeAll { m in
            m.deliveredAt.map { now.timeIntervalSince($0) > 8 * 86_400 } == true
                && !(m.kind == .task && m.taskId.map(open.contains) == true)
        }
        var expired: [MailTask] = []
        for i in tasks.indices where tasks[i].status == .open && tasks[i].deadline <= now {
            close(i, .expired, at: now)
            dropUndelivered(task: tasks[i])
            tellRequester(tasks[i], .expired, at: now)
            expired.append(tasks[i])
        }
        return expired
    }

    /// A bot archived (spec §5, §10): the messages waiting for it are dropped (returned, for the log); its open tasks,
    /// asked or given, are cancelled with a notice to the other bot.
    public mutating func archive(_ bot: UUID, at now: Date) -> (closed: [MailTask], dropped: [MailMessage]) {
        let dropped = waiting(for: bot)
        messages.removeAll { $0.to == bot && $0.deliveredAt == nil }
        var closed: [MailTask] = []
        for i in tasks.indices where tasks[i].status == .open && (tasks[i].from == bot || tasks[i].to == bot) {
            close(i, .cancelled, at: now)
            if tasks[i].from == bot { tellRecipient(tasks[i], .cancelledArchived, at: now) }
            else { tellRequester(tasks[i], .cancelledArchived, at: now) }
            closed.append(tasks[i])
        }
        return (closed, dropped)
    }

    // MARK: - Private

    @discardableResult
    private mutating func post(from: UUID?, to: UUID, kind: MailKind, text: String, task: Int?,
                               notice: MailNotice? = nil, at now: Date) -> MailMessage {
        let message = MailMessage(id: UUID(), from: from, to: to, kind: kind, text: text, taskId: task, notice: notice,
                                  createdAt: now)
        messages.append(message)
        return message
    }

    /// A notice to the task's recipient; one that never got the task hears nothing: its message is dropped instead.
    private mutating func tellRecipient(_ t: MailTask, _ notice: MailNotice, text: String = "", at now: Date) {
        guard !dropUndelivered(task: t) else { return }
        post(from: t.from, to: t.to, kind: .system, text: text, task: t.number, notice: notice, at: now)
    }

    private mutating func tellRequester(_ t: MailTask, _ notice: MailNotice, at now: Date) {
        post(from: t.to, to: t.from, kind: .system, text: "", task: t.number, notice: notice, at: now)
    }

    @discardableResult
    private mutating func dropUndelivered(task t: MailTask) -> Bool {
        guard let i = messages.firstIndex(where: { $0.kind == .task && $0.taskId == t.number && $0.deliveredAt == nil })
        else { return false }
        messages.remove(at: i)
        return true
    }

    private func openTask(_ number: Int) throws -> Int {
        guard let i = tasks.firstIndex(where: { $0.number == number }) else {
            throw MailError("there is no task #\(number)")
        }
        guard tasks[i].status == .open else {
            throw MailError("task #\(number) is already \(tasks[i].status.rawValue)")
        }
        return i
    }

    private mutating func close(_ i: Int, _ status: TaskStatus, result: String? = nil, at now: Date) {
        (tasks[i].status, tasks[i].result, tasks[i].closedAt) = (status, result, now)
    }

    private static func checkSize(_ text: String) throws {
        guard text.utf8.count <= maxBytes else {
            throw MailError("the text is longer than 64 KB: put it in a file in the project's shared folder "
                            + "and send its path")
        }
    }
}

/// The active bot called `name` among a project's bots, in any case (spec §4); two active bots with that name are an
/// error, so is an archived one.
public func mailBot(named name: String, in bots: [Bot]) throws -> Bot {
    let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let same = bots.filter {
        $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame
    }
    let active = same.filter { $0.archivedAt == nil }
    guard active.count < 2 else { throw MailError("two bots are called \(active[0].name): rename one in Serif") }
    guard let bot = active.first else {
        throw MailError(same.isEmpty ? "no bot of this project is called \(wanted)" : "\(same[0].name) is archived")
    }
    return bot
}
