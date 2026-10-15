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

    public init(dueAt: Date, signal: RunSignal? = nil) { self.dueAt = dueAt; self.signal = signal }
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
