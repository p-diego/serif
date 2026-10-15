import Foundation

// What the bots read about their routines and decisions (spec §4–6): English, like the mail's texts.

/// The text of a routine's turn (spec §4): which run this is and its limit, the signal that started it if one did,
/// then the prompt.
public func routineTurnText(_ r: Routine, run: Int, startedAt: Date, signal: RunSignal?,
                            timeZone: TimeZone = .current) -> String {
    var s = "Routine «\(r.name)» (run of \(mailDate(startedAt, timeZone: timeZone)); this is run #\(run)). "
        + "Stay within this job and finish within \(r.maxMinutes) minutes.\n\n"
    if let signal {
        s += "Started by the signal «\(signal.name)» from \(signal.from)" + (signal.text.map { ": \($0)" } ?? "") + "\n\n"
    }
    return s + r.prompt
}

/// A trigger in words, for the bots: "every 30 minutes", "daily at 09:00", "on Mon, Fri at 09:00", "on the signal
/// «build-done»", "cron 0 9 * * 1-5".
public func triggerText(_ t: RoutineTrigger) -> String {
    switch t {
    case .every(let m): m == 60 ? "every hour" : m % 60 == 0 ? "every \(m / 60) hours" : "every \(m) minutes"
    case .dailyAt(let h, let m): "daily at \(clockText(h, m))"
    case .weekdaysAt(let days, let h, let m):
        // A day outside 1–7 can only come from a corrupt routines.json: skipped, never a crash.
        "on " + days.sorted().filter { (1...7).contains($0) }
            .map { ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][$0 - 1] }.joined(separator: ", ")
            + " at \(clockText(h, m))"
    case .signal(let name): "on the signal «\(name)»"
    case .cron(let e): "cron \(e)"
    }
}

public func clockText(_ hour: Int, _ minute: Int) -> String {
    String(format: "%02d:%02d", hour, minute)
}

/// `list_routines` (spec §4): the caller's routines with their trigger, state, next run (`next` gives it) and last
/// outcome.
public func routinesText(_ routines: [Routine], next: (Routine) -> Date?, timeZone: TimeZone = .current) -> String {
    guard !routines.isEmpty else { return "You have no routines." }
    return "Your routines:\n" + routines.map { r in
        var parts: [String] = []
        if r.enabled, let due = next(r) { parts.append("next run \(mailDate(due, timeZone: timeZone))") }
        if r.pending != nil { parts.append("a run is waiting for you to be free") }
        if let last = r.lastRunAt {
            parts.append("last run \(mailDate(last, timeZone: timeZone)), \(r.lastOutcome?.rawValue ?? "running")")
        }
        return "- «\(r.name)» (\(triggerText(r.trigger)), \(r.enabled ? "on" : "off"), up to \(r.maxMinutes) min): "
            + (parts.isEmpty ? "never ran" : parts.joined(separator: "; "))
    }.joined(separator: "\n")
}

/// The answer to a decision as one line: the option, the text, or both (spec §6).
public func decisionAnswerText(_ d: Decision) -> String {
    [d.answer?.option.flatMap { d.options.indices.contains($0) ? d.options[$0] : nil }, d.answer?.text]
        .compactMap { $0 }.joined(separator: " — ")
}

/// The mail the bot gets when you answer (spec §6): `Your decision on #5 «<question>»: <option> — <text>`.
public func decisionMailText(_ d: Decision) -> String {
    "Your decision on #\(d.number) «\(d.question)»: \(decisionAnswerText(d))"
}

/// The lead's copy (spec §6): `Decision #5 of Cody «<question>» was answered by the user: <answer>`.
public func decisionLeadText(_ d: Decision, botName: String) -> String {
    "Decision #\(d.number) of \(botName) «\(d.question)» was answered by the user: \(decisionAnswerText(d))"
}

/// `list_decisions` (spec §6): the project's decisions, open first, each with its options and its answer.
public func decisionsText(_ decisions: [Decision], name: (UUID) -> String, timeZone: TimeZone = .current) -> String {
    guard !decisions.isEmpty else { return "No decisions in this project." }
    let sorted = decisions.sorted { ($0.status != .open ? 1 : 0, -$0.number) < ($1.status != .open ? 1 : 0, -$1.number) }
    return "Decisions of this project:\n" + sorted.map { d in
        let options = d.options.enumerated().map { "\($0 + 1). \($1)" + ($0 == d.recommendation ? " (recommended)" : "") }
        var line = "- #\(d.number) by \(name(d.botId)), \(mailDate(d.createdAt, timeZone: timeZone)): «\(d.question)» "
            + options.joined(separator: "; ")
        switch d.status {
        case .open: line += " — open"
        case .answered: line += " — answered: \(decisionAnswerText(d))"
        case .withdrawn: line += " — withdrawn" + (d.reason.map { ": \($0)" } ?? "")
        }
        return line
    }.joined(separator: "\n")
}
