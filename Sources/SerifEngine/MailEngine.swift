import Foundation
import SerifCore

// The bots' own tools and their mail (spec §4–6): calls from serif-tools on hook.sock, answered at once; the mail they
// cause, saved in the project's mail.json and delivered to each bot when it is free.
extension Engine {
    /// A call of `rt`'s Serif tools; the answer is a text the model reads, an error when a rule says no (spec §4).
    func handleTool(_ name: String, _ arguments: JSONValue, from rt: BotRuntime) -> ToolResult {
        do {
            switch name {
            case "send_message": return ToolResult(try sendMessage(arguments, from: rt))
            case "complete_task": return ToolResult(try completeTask(arguments, from: rt))
            case "cancel_task": return ToolResult(try cancelTask(arguments, from: rt))
            case "check_inbox": return ToolResult(try checkInbox(from: rt))
            case "list_bots": return ToolResult(listBots(for: rt))
            default: return ToolResult("Serif has no tool called \(name)", isError: true)
            }
        } catch let refusal as MailError {
            return ToolResult(refusal.text, isError: true)
        } catch {
            log("bot \(rt.bot.id): \(name) failed: \(error)")
            return ToolResult("Serif could not do it: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Tools

    /// `send_message` (spec §4-5): the sender's chat shows the line, and the task's card for a task; the recipient gets
    /// it as soon as it is free.
    private func sendMessage(_ a: JSONValue, from rt: BotRuntime) throws -> String {
        guard let name = a["to"]?.string, let body = a["body"]?.string else {
            throw MailError("send_message needs to and body")
        }
        let to = try mailBot(named: name, in: projectBots(rt))
        guard to.id != rt.bot.id else { throw MailError("you cannot write to yourself") }
        var box = store.mailbox(rt.bot.projectId)
        var task: MailTask?
        switch a["kind"]?.string {
        case "task":
            let hours = try number(a["deadline_hours"], "deadline_hours")
            task = try box.sendTask(from: rt.bot.id, to: to.id, text: body, hours: hours, turnTask: rt.turnTask,
                                    at: now())
        case let kind? where kind == "reply" || kind == "note":
            try box.sendMessage(from: rt.bot.id, to: to.id, kind: kind == "reply" ? .reply : .note, text: body,
                                task: try number(a["task_id"], "task_id"), at: now())
        default:
            throw MailError("kind must be task, reply or note")
        }
        let sent = box.messages[box.messages.count - 1]          // the message the move posted
        try store.save(box, project: rt.bot.projectId)
        if let task { record(.task(card(task)), rt) }
        record(.mail(note(sent, .sent, in: box)), rt)
        bots[to.id].map(deliverMail)
        guard let task else { return "Sent to \(to.name)" }
        return "Task #\(task.number) sent to \(to.name), deadline \(mailDate(task.deadline))"
    }

    /// `complete_task` (spec §5): the result goes to the requester, a copy to the lead; the cards change in place.
    private func completeTask(_ a: JSONValue, from rt: BotRuntime) throws -> String {
        guard let n = try number(a["task_id"], "task_id"), let result = a["result"]?.string else {
            throw MailError("complete_task needs task_id and result")
        }
        var box = store.mailbox(rt.bot.projectId)
        let lead = store.projects.first { $0.id == rt.bot.projectId }?.leadBotId
        let task = try box.complete(n, by: rt.bot.id, result: result, lead: lead, at: now())
        try store.save(box, project: rt.bot.projectId)
        taskChanged(task, in: box)
        if let reply = box.messages.last(where: { $0.kind == .reply && $0.taskId == n }) {
            record(.mail(note(reply, .sent, in: box)), rt)
        }
        deliverMail(in: rt.bot.projectId)
        return "Task #\(n) closed; \(botName(task.from)) has been told"
    }

    private func cancelTask(_ a: JSONValue, from rt: BotRuntime) throws -> String {
        guard let n = try number(a["task_id"], "task_id") else { throw MailError("cancel_task needs task_id") }
        try cancelTask(n, in: rt.bot.projectId, by: rt.bot.id, reason: a["reason"]?.string)
        return "Task #\(n) cancelled"
    }

    /// A task cancelled by the bot that asked, or by the user's Cancel (`by` nil, spec §5); the other side is told.
    func cancelTask(_ n: Int, in project: UUID, by bot: UUID?, reason: String?) throws {
        var box = store.mailbox(project)
        let task = try box.cancel(n, by: bot, reason: reason, at: now())
        try store.save(box, project: project)
        taskChanged(task, in: box)
        deliverMail(in: project)
    }

    /// `check_inbox` (spec §4, §6): what waits for the bot counts as delivered from now on, and its chat shows it as
    /// received; a task read so heads no chain.
    private func checkInbox(from rt: BotRuntime) throws -> String {
        var box = store.mailbox(rt.bot.projectId)
        let new = box.waiting(for: rt.bot.id)
        let text = inboxText(box, for: rt.bot.id, new: new, name: botName, now: now())
        for message in new { received(message, by: rt, in: &box) }
        if !new.isEmpty { try store.save(box, project: rt.bot.projectId) }
        return text
    }

    /// `list_bots` (spec §4), with the project's lead as it is now (spec §8).
    private func listBots(for rt: BotRuntime) -> String {
        let lead = store.projects.first { $0.id == rt.bot.projectId }?.leadBotId
        let mates = projectBots(rt).map { ($0, bots[$0.id]?.tracker.state ?? .stopped) }
        return colleaguesText(mates, caller: rt.bot.id, lead: lead)
    }

    // MARK: - Delivery

    /// Free for mail (spec §6): running and ready, no turn on its way or running, no card open, nothing of the user's
    /// waiting to go in first.
    func isFree(_ rt: BotRuntime) -> Bool {
        guard rt.bot.archivedAt == nil, !rt.stopping, rt.tracker.state == .ready, !hasOpenRequest(rt), rt.outbox.isEmpty
        else { return false }
        if rt.bot.agent == .codex { return rt.codexReady && !rt.sending && rt.turnId == nil }
        return rt.host.isRunning && !rt.awaitingEcho
    }

    /// Starts a turn with the oldest message waiting for `rt` once it is free (spec §6): one at a time, the next at the
    /// end of that turn. Never added to a running turn (`turn/steer`, or typed into Claude Code while it works).
    func deliverMail(_ rt: BotRuntime) {
        guard isFree(rt) else { return }
        var box = store.mailbox(rt.bot.projectId)
        guard let message = box.waiting(for: rt.bot.id).first else { return }
        let text = mailTurnText(message, task: message.taskId.flatMap(box.task), name: botName)
        received(message, by: rt, in: &box)
        save(box, rt.bot.projectId)
        // A task given now heads the chain of the tasks this turn creates (spec §5).
        rt.turnTask = message.kind == .task ? message.taskId : nil
        // ponytail: delivered once handed over; a Codex server that dies before taking the turn/start keeps the text
        // only in memory (sendTurn puts it back in the outbox), so an engine restart in that second loses it.
        if rt.bot.agent == .codex {
            rt.outbox.append((text, .bot))
            deliverCodex(rt)
        } else {
            type(text, origin: .bot, into: rt)
        }
    }

    /// Every free bot of the project gets what waits for it.
    func deliverMail(in project: UUID) {
        for rt in bots.values where rt.bot.projectId == project { deliverMail(rt) }
    }

    /// A task's new state, in place on its cards (spec §6): the requester's, and the recipient's once it had the task.
    func taskChanged(_ task: MailTask, in box: Mailbox) {
        if let requester = bots[task.from] { record(.task(card(task)), requester) }
        if box.delivered(task: task.number), let recipient = bots[task.to] { record(.task(card(task)), recipient) }
    }

    /// A message `rt` has now (a turn, or `check_inbox`): delivered, and in its chat the task's card first for a task,
    /// then the bubble (spec §6).
    private func received(_ message: MailMessage, by rt: BotRuntime, in box: inout Mailbox) {
        box.markDelivered(message.id, at: now())
        if message.kind == .task, let task = message.taskId.flatMap(box.task) { record(.task(card(task)), rt) }
        record(.mail(note(message, .received, in: box)), rt)
    }

    // MARK: - Pieces

    /// The project's bots, archived ones too (names resolve against all of them, spec §4).
    func projectBots(_ rt: BotRuntime) -> [Bot] { store.bots.filter { $0.projectId == rt.bot.projectId } }

    func botName(_ id: UUID) -> String { store.bots.first { $0.id == id }?.name ?? "a former bot" }

    func card(_ task: MailTask) -> TaskCard {
        TaskCard(number: task.number, from: botName(task.from), to: botName(task.to), text: task.text,
                 deadline: task.deadline, status: task.status, result: task.result)
    }

    /// The engine's own moves (deliveries, expiry, archiving) go on when the file cannot be written: the log says so.
    func save(_ box: Mailbox, _ project: UUID) {
        do { try store.save(box, project: project) } catch { log("mail of project \(project) not saved: \(error)") }
    }

    /// A notice keeps its whole English text, which the app shows on request (spec §9).
    func note(_ message: MailMessage, _ direction: MailDirection, in box: Mailbox) -> MailNote {
        let text = message.kind == .system
            ? mailTurnText(message, task: message.taskId.flatMap(box.task), name: botName) : message.text
        return MailNote(messageId: message.id, kind: message.kind, from: botName(message.from), to: botName(message.to),
                        direction: direction, text: text, taskNumber: message.taskId, notice: message.notice)
    }
}

/// A whole number a model gave as a number or as text ("17", "#17"); nil when left out.
private func number(_ v: JSONValue?, _ field: String) throws -> Int? {
    guard let v, v != .null else { return nil }
    if let n = v.int ?? v.string.flatMap({ Int($0.trimmingCharacters(in: .init(charactersIn: "# "))) }) { return n }
    throw MailError("\(field) must be a whole number")
}
