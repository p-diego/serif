import Foundation

// What the bots read about their mail (spec §4, §6): English, like the system prompt.

/// How a bot works with its colleagues (spec §4, §9): the `instructions` of Serif's tools server, and the same words in
/// every bot's system prompt.
public let serifToolsGuide = """
    You work with the other bots of this project through Serif's tools (the "serif" server). list_bots shows who is \
    here and what each one does. To hand a colleague a piece of work, send_message with kind "task": its answer \
    comes later as a new message that starts a turn of yours, so do not wait or poll for it. Use kind "note" to tell \
    something, and kind "reply" with task_id for a question or an answer about an open task. When you get a task, \
    do it and close it with complete_task and your result: the bot that asked is waiting for exactly that. \
    check_inbox shows your open tasks and messages that arrived while you were busy. Bots never see each other's \
    chats: put everything the other bot needs in the message, and pass files through the project's shared folder, \
    naming their paths. A job that needs a bot of its own can get one with create_bot; you may change your own \
    instructions and those of the bots you created (update_instructions) and archive the bots you created \
    (archive_bot).
    """

/// A date as bots read it: "16 Oct 2026, 18:05", in the Mac's time zone.
public func mailDate(_ date: Date, timeZone: TimeZone = .current) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    f.dateFormat = "d MMM yyyy, HH:mm"
    return f.string(from: date)
}

/// The text of the turn that delivers `message` (spec §6), also its entry in `check_inbox`; `name` gives a bot's name.
public func mailTurnText(_ message: MailMessage, task: MailTask?, name: (UUID) -> String,
                         timeZone: TimeZone = .current) -> String {
    let number = message.taskId ?? 0
    switch message.kind {
    case .task:
        let deadline = task.map { mailDate($0.deadline, timeZone: timeZone) } ?? "none"
        return "Task #\(number) from \(name(message.from)), a bot of this project (deadline \(deadline)). "
            + "When done, call complete_task with task_id \(number).\n\n\(message.text)"
    case .reply where message.notice == .done:
        return "Reply from \(name(message.from)) to your task #\(number), now done:\n\n\(message.text)"
    case .reply:
        return "Reply from \(name(message.from)) about task #\(number):\n\n\(message.text)"
    case .note:
        return "Note from \(name(message.from)):\n\n\(message.text)"
    case .system:
        guard let t = task else { return "Task #\(number): \(message.notice?.rawValue ?? "notice")" }
        // Seen from whoever gets it: the recipient, the requester, or the lead.
        let subject = message.to == t.to ? "Task #\(t.number) from \(name(t.from))"
            : message.to == t.from ? "Task #\(t.number) to \(name(t.to))"
            : "Task #\(t.number) (\(name(t.from)) → \(name(t.to)))"
        switch message.notice {
        case .done?: return "\(subject) is done:\n\n\(message.text)"
        case .cancelledByRequester?:
            return "\(subject) was cancelled by \(name(t.from))" + (message.text.isEmpty ? "" : ": \(message.text)")
        case .cancelledByUser?: return "\(subject) was cancelled by the user"
        case .cancelledArchived?:
            return "\(subject) was cancelled: \(name(message.to == t.to ? t.from : t.to)) was archived"
        case .expired?: return "\(subject) expired without a reply"
        case nil: return subject
        }
    }
}

/// `list_bots` (spec §4): the project's active bots, each with the first line of its instructions, its state, its
/// agent, and whether it is the lead or one the caller created.
public func colleaguesText(_ bots: [(bot: Bot, state: BotState)], caller: UUID, lead: UUID?) -> String {
    let lines = bots.filter { $0.bot.archivedAt == nil }.map { bot, state in
        var marks = [statusWord(state), bot.agent == .codex ? "Codex" : "Claude Code"]
        if bot.id == lead { marks.append("lead") }
        if bot.createdBy == caller { marks.append("created by you") }
        let role = bot.instructions.split(separator: "\n").first.map { ": " + $0.prefix(120) } ?? ""
        return "- \(bot.name)\(bot.id == caller ? " (you)" : "")\(role) [\(marks.joined(separator: ", "))]"
    }
    return "Bots of this project:\n" + lines.joined(separator: "\n")
}

private func statusWord(_ state: BotState) -> String {
    switch state {
    case .ready: "ready"
    case .working: "working"
    case .waiting: "waiting for the user"
    case .starting: "starting"
    case .rateLimited: "at its usage limit"
    case .crashed, .stopped: "stopped"
    }
}

/// `check_inbox` (spec §4): the open tasks given to `bot`, the tasks it asked for (open, or closed in the last day)
/// with their state, and in full the messages it had not had yet (`new`, delivered from now on).
public func inboxText(_ box: Mailbox, for bot: UUID, new: [MailMessage], name: (UUID) -> String, now: Date,
                      timeZone: TimeZone = .current) -> String {
    var parts: [String] = []
    let given = box.tasks.filter { $0.to == bot && $0.status == .open }
    if !given.isEmpty {
        parts.append("Open tasks given to you:\n" + given.map {
            "- #\($0.number) from \(name($0.from)), deadline \(mailDate($0.deadline, timeZone: timeZone)): "
                + ($0.text.split(separator: "\n").first.map { String($0.prefix(120)) } ?? "")
        }.joined(separator: "\n"))
    }
    let asked = box.tasks.filter {
        $0.from == bot && ($0.status == .open || $0.closedAt.map { now.timeIntervalSince($0) < 86_400 } == true)
    }
    if !asked.isEmpty {
        parts.append("Tasks you asked for:\n" + asked.map { t in
            let state = t.status == .open ? "open, deadline \(mailDate(t.deadline, timeZone: timeZone))"
                : t.status.rawValue
            return "- #\(t.number) to \(name(t.to)): \(state)"
        }.joined(separator: "\n"))
    }
    if !new.isEmpty {
        parts.append("New messages:\n\n" + new.map {
            mailTurnText($0, task: $0.taskId.flatMap(box.task), name: name, timeZone: timeZone)
        }.joined(separator: "\n\n---\n\n"))
    }
    return parts.isEmpty ? "No open tasks and no new messages." : parts.joined(separator: "\n\n")
}
