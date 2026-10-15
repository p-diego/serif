import Foundation

// Routines: turns a bot runs on its own, on a schedule or on a signal (spec §4–5 of 0.6).

/// When a routine runs (spec §4): `days` are 1 = Monday … 7 = Sunday; `cron` has the five classic fields and comes
/// only from the tools (the sheet shows it as it is).
public enum RoutineTrigger: Codable, Equatable, Sendable {
    case every(minutes: Int)
    case dailyAt(hour: Int, minute: Int)
    case weekdaysAt(days: Set<Int>, hour: Int, minute: Int)
    case signal(name: String)
    case cron(expression: String)
}

/// How a run ended (spec §4): normally, stopped by the engine at its time limit, failed or crashed, or stopped by you.
public enum RoutineOutcome: String, Codable, Sendable { case done, stopped, failed, interrupted }

public enum RoutineCreator: String, Codable, Sendable { case user, bot }

/// The signal that put a run in wait (spec §5): its name, its text, who sent it (the name as it was then) and how long
/// the chain of signals is at this run.
public struct RunSignal: Codable, Equatable, Sendable {
    public var name: String
    public var text: String?
    public var from: String
    public var chain: Int

    public init(name: String, text: String?, from: String, chain: Int) {
        self.name = name; self.text = text; self.from = from; self.chain = chain
    }
}

/// A run waiting for its bot to be free (spec §4): one per routine at most.
public struct PendingRun: Codable, Equatable, Sendable {
    public var dueAt: Date
    public var signal: RunSignal?
    /// How many runs of this kind led here (spec §5): 0 for the clock and "Run now", one more for each signal or
    /// `run_routine` of a run that is itself a link.
    public var chain: Int

    public init(dueAt: Date, signal: RunSignal? = nil, chain: Int = 0) {
        self.dueAt = dueAt; self.signal = signal; self.chain = chain
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dueAt = try c.decode(Date.self, forKey: .dueAt)
        signal = try c.decodeIfPresent(RunSignal.self, forKey: .signal)
        chain = try c.decodeIfPresent(Int.self, forKey: .chain) ?? signal?.chain ?? 0
    }
}

/// A job a bot runs by itself (spec §4), saved in its project's `routines.json`.
public struct Routine: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var botId: UUID
    public var name: String
    public var trigger: RoutineTrigger
    public var prompt: String
    /// A run longer than this is stopped (spec §4): 1–480, 30 by default.
    public var maxMinutes: Int
    /// "Tell me when it finishes": a finished run notifies like a turn of yours (spec §2).
    public var notifies: Bool
    public var enabled: Bool
    public var createdBy: RoutineCreator
    public var createdAt: Date
    public var lastRunAt: Date?
    /// nil while a run is on, or before the first.
    public var lastOutcome: RoutineOutcome?
    public var pending: PendingRun?
    /// How many runs have started: "this is run #12" in the turn's text (spec §4).
    public var runs: Int

    public init(id: UUID = UUID(), botId: UUID, name: String, trigger: RoutineTrigger, prompt: String, maxMinutes: Int = 30,
                notifies: Bool = true, enabled: Bool = true, createdBy: RoutineCreator, createdAt: Date = Date(),
                lastRunAt: Date? = nil, lastOutcome: RoutineOutcome? = nil, pending: PendingRun? = nil, runs: Int = 0) {
        self.id = id; self.botId = botId; self.name = name; self.trigger = trigger; self.prompt = prompt
        self.maxMinutes = maxMinutes; self.notifies = notifies; self.enabled = enabled; self.createdBy = createdBy
        self.createdAt = createdAt; self.lastRunAt = lastRunAt; self.lastOutcome = lastOutcome; self.pending = pending
        self.runs = runs
    }

    // A routines.json missing a field added later still loads (spec §10): the defaults of the sheet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        botId = try c.decode(UUID.self, forKey: .botId)
        name = try c.decode(String.self, forKey: .name)
        trigger = try c.decode(RoutineTrigger.self, forKey: .trigger)
        prompt = try c.decode(String.self, forKey: .prompt)
        maxMinutes = try c.decodeIfPresent(Int.self, forKey: .maxMinutes) ?? 30
        notifies = try c.decodeIfPresent(Bool.self, forKey: .notifies) ?? true
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdBy = try c.decodeIfPresent(RoutineCreator.self, forKey: .createdBy) ?? .user
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastOutcome = try c.decodeIfPresent(RoutineOutcome.self, forKey: .lastOutcome)
        pending = try c.decodeIfPresent(PendingRun.self, forKey: .pending)
        runs = try c.decodeIfPresent(Int.self, forKey: .runs) ?? 0
    }
}

/// A routine's run as the bot's chat shows it (spec §4): recorded when it starts, again with its outcome; the chat
/// updates the first record in place (matched by routine and start).
public struct RoutineRun: Codable, Equatable, Sendable {
    public var routineId: UUID
    public var name: String
    public var startedAt: Date
    public var maxMinutes: Int
    public var notifies: Bool
    public var signal: RunSignal?
    public var outcome: RoutineOutcome?

    public init(routineId: UUID, name: String, startedAt: Date, maxMinutes: Int, notifies: Bool, signal: RunSignal? = nil,
                outcome: RoutineOutcome? = nil) {
        self.routineId = routineId; self.name = name; self.startedAt = startedAt; self.maxMinutes = maxMinutes
        self.notifies = notifies; self.signal = signal; self.outcome = outcome
    }
}

// MARK: - Rules (spec §4–5)

public enum RoutineRules {
    public static let maxPerBot = 20, maxPromptBytes = 16_384, minEveryMinutes = 5, minutes = 1...480
    public static let maxSignalChain = 4, maxSignalNameLength = 64, maxSignalBytes = 4096
}

/// The error `create_routine` answers when the bot has 20 routines, nil when there is room (spec §4); the sheet has no
/// limit.
public func routineLimitError(count: Int) -> String? {
    count < RoutineRules.maxPerBot ? nil : "you already have \(RoutineRules.maxPerBot) routines: delete one first"
}

/// Why `routine` cannot be saved among `others` (its project's routines), or nil: a sentence for the bot and the sheet.
public func routineProblem(_ r: Routine, among others: [Routine]) -> String? {
    let name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return "the routine needs a name" }
    let taken = others.contains {
        $0.id != r.id && $0.botId == r.botId && $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
    }
    if taken { return "you already have a routine called \(name)" }
    if r.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "the routine needs a prompt" }
    if r.prompt.utf8.count > RoutineRules.maxPromptBytes { return "the prompt is longer than 16 KB" }
    if !RoutineRules.minutes.contains(r.maxMinutes) { return "max_minutes must be between 1 and 480" }
    return triggerProblem(r.trigger)
}

public func triggerProblem(_ t: RoutineTrigger) -> String? {
    switch t {
    case .every(let m): m >= RoutineRules.minEveryMinutes ? nil : "every_minutes must be at least 5"
    case .dailyAt(let h, let m): timeProblem(h, m)
    case .weekdaysAt(let days, let h, let m):
        days.isEmpty || !days.isSubset(of: 1...7) ? "days must be between 1 (Monday) and 7 (Sunday)" : timeProblem(h, m)
    case .signal(let name): signalNameProblem(name)
    case .cron(let e): cronProblem(e)
    }
}

/// A cron that does not parse, or never fires within a year (say, 31 February), is refused at creation.
private func cronProblem(_ e: String) -> String? {
    guard let cron = CronSchedule(e) else { return "cron must have five fields: minute hour day month weekday" }
    return cron.next(after: Date(), calendar: .current) == nil ? "this cron expression never runs" : nil
}

private func timeProblem(_ hour: Int, _ minute: Int) -> String? {
    (0...23).contains(hour) && (0...59).contains(minute) ? nil : "the time must be HH:MM, from 00:00 to 23:59"
}

/// A signal's name (spec §5): 1–64 characters, no spaces.
public func signalNameProblem(_ name: String) -> String? {
    name.isEmpty || name.count > RoutineRules.maxSignalNameLength || name.contains(where: \.isWhitespace)
        ? "the signal name must be 1 to 64 characters with no spaces" : nil
}

/// "HH:MM" as the tools and the sheet give a time; nil when it is not one.
public func clockTime(_ text: String) -> (hour: Int, minute: Int)? {
    let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), timeProblem(h, m) == nil else { return nil }
    return (h, m)
}

// MARK: - Schedule (spec §4)

/// When `routine` is next due: the first time after its last run (or its creation) and after `notBefore`, in the Mac's
/// time (`calendar`); nil for a signal routine, which the clock never starts. `every` keeps its cadence from the last
/// run; the others take the next occurrence (a time that does not exist on a clock change moves to the next one).
public func nextRun(of r: Routine, notBefore: Date? = nil, calendar: Calendar = .current) -> Date? {
    let base = r.lastRunAt ?? r.createdAt
    let after = max(base, notBefore ?? .distantPast)
    switch r.trigger {
    case .every(let minutes):
        let step = Double(minutes) * 60
        let k = (after.timeIntervalSince(base) / step).rounded(.down) + 1
        return base.addingTimeInterval(k * step)
    case .dailyAt(let h, let m):
        return calendar.nextDate(after: after, matching: DateComponents(hour: h, minute: m), matchingPolicy: .nextTime)
    case .weekdaysAt(let days, let h, let m):
        // Our Monday is 1; Calendar's Sunday is 1.
        return days.compactMap {
            calendar.nextDate(after: after, matching: DateComponents(hour: h, minute: m, weekday: $0 % 7 + 1),
                              matchingPolicy: .nextTime)
        }.min()
    case .signal:
        return nil
    case .cron(let e):
        return CronSchedule(e)?.next(after: after, calendar: calendar)
    }
}

/// A classic five-field cron expression (minute, hour, day of month, month, weekday with 0 or 7 = Sunday): `*`, lists,
/// ranges and steps, as Gravity reads them (spec §4). Nothing else: no names, no `L` or `#`.
public struct CronSchedule: Equatable, Sendable {
    let minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    let anyDay: Bool, anyWeekday: Bool

    public init?(_ expression: String) {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5,
              let minutes = Self.parse(fields[0], 0...59), let hours = Self.parse(fields[1], 0...23),
              let days = Self.parse(fields[2], 1...31), let months = Self.parse(fields[3], 1...12),
              let weekdays = Self.parse(fields[4], 0...7) else { return nil }
        (self.minutes, self.hours, self.days, self.months) = (minutes, hours, days, months)
        self.weekdays = Set(weekdays.map { $0 % 7 })          // 7 is Sunday too
        (anyDay, anyWeekday) = (fields[2] == "*", fields[4] == "*")
    }

    private static func parse(_ field: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var out = Set<Int>()
        for part in field.split(separator: ",") {
            let pieces = part.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let step = pieces.count == 2 ? Int(pieces[1]) : 1, step >= 1 else { return nil }
            let span: ClosedRange<Int>
            if pieces[0] == "*" {
                span = range
            } else if let dash = pieces[0].firstIndex(of: "-") {
                guard let a = Int(pieces[0][..<dash]), let b = Int(pieces[0][pieces[0].index(after: dash)...]), a <= b
                else { return nil }
                span = a...b
            } else {
                guard let a = Int(pieces[0]) else { return nil }
                span = pieces.count == 2 ? a...range.upperBound : a...a      // "5/10": from 5 on, every 10
            }
            guard range.contains(span.lowerBound), range.contains(span.upperBound) else { return nil }
            out.formUnion(stride(from: span.lowerBound, through: span.upperBound, by: step))
        }
        return out.isEmpty ? nil : out
    }

    /// The first matching minute after `after`, within a year; nil when there is none (say, 31 February).
    public func next(after: Date, calendar: Calendar) -> Date? {
        var day = calendar.startOfDay(for: after)
        for _ in 0..<366 {
            let c = calendar.dateComponents([.month, .day, .weekday], from: day)
            let weekday = (c.weekday ?? 1) - 1                 // Calendar's Sunday 1 is cron's 0
            // Both day fields given: either one matches, as cron has it.
            let dayMatches = anyDay ? weekdays.contains(weekday)
                : anyWeekday ? days.contains(c.day ?? 0)
                : days.contains(c.day ?? 0) || weekdays.contains(weekday)
            if months.contains(c.month ?? 0), dayMatches {
                for h in hours.sorted() {
                    for m in minutes.sorted() {
                        if let t = calendar.date(bySettingHour: h, minute: m, second: 0, of: day), t > after { return t }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }
}
