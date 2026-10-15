import Foundation
import SerifCore

// Routines and signals (spec §4–5 of 0.6): saved in the project's routines.json, due runs found by the 60 s sweep and
// started like mail once the bot is free, the bot's own tools, the sheet's requests.
extension Engine {
    // MARK: - The sweep

    /// At the engine's start (spec §4): the clock starts here, so a run whose time passed while the engine was off is
    /// not made up, only logged. A `PendingRun` saved on disk was already due: it starts once its bot is free.
    func routinesStarted() {
        routineFloor = now()
        for project in store.projects {
            for r in store.routines(project.id) where r.enabled && r.pending == nil {
                if let due = nextRun(of: r), due < routineFloor {
                    log("routine «\(r.name)» of \(botName(r.botId)): missed at \(mailDate(due))")
                }
            }
        }
    }

    /// Every 60 s (spec §4): a run now due waits for its bot (one at most per routine); a run past its routine's time
    /// limit is stopped as your Stop would (again at every sweep until the turn ends).
    func routineSweep() {
        let now = now()
        for project in store.projects {
            var routines = store.routines(project.id)
            var changed = false
            for i in routines.indices where routines[i].enabled && routines[i].pending == nil {
                guard let due = nextRun(of: routines[i], notBefore: routineFloor), due <= now else { continue }
                routines[i].pending = PendingRun(dueAt: due)
                changed = true
            }
            guard changed else { continue }
            save(routines, project.id)
            push(.routinesChanged(projectId: project.id, routines: routines))
            deliverMail(in: project.id)
        }
        for rt in bots.values {
            guard let run = rt.run, rt.tracker.state.inTurn,
                  now.timeIntervalSince(run.startedAt) >= Double(run.maxMinutes) * 60 else { continue }
            // Repeated at every sweep while the turn goes on, in case the Esc never got through (plan note 19).
            if rt.runEnding == nil {
                log("bot \(rt.bot.id): routine «\(run.name)» stopped after \(run.maxMinutes) min")
                rt.runEnding = .stopped
            }
            stopTurn(rt)
        }
    }

    /// Stops the bot's running turn as your Stop does (spec §4): Esc for Claude Code, `turn/interrupt` for Codex.
    func stopTurn(_ rt: BotRuntime) {
        if rt.bot.agent == .codex { interruptCodex(rt) } else { rt.host.pressEscape() }
    }

    // MARK: - Runs

    /// With no mail waiting, the oldest due run of the bot starts its turn (spec §4): the routine notes the start, the
    /// chat gets the run's header, and the text goes in with origin `.routine`, never into a running turn.
    func startPendingRun(_ rt: BotRuntime) {
        guard isFree(rt) else { return }
        var routines = store.routines(rt.bot.projectId)
        let due = routines.indices.filter { routines[$0].botId == rt.bot.id && routines[$0].pending != nil }
        guard let i = due.min(by: { routines[$0].pending!.dueAt < routines[$1].pending!.dueAt }),
              let pending = routines[i].pending else { return }
        let started = now()
        (routines[i].pending, routines[i].lastRunAt, routines[i].lastOutcome) = (nil, started, nil)
        routines[i].runs += 1
        let routine = routines[i]
        save(routines, rt.bot.projectId)
        push(.routinesChanged(projectId: rt.bot.projectId, routines: routines))
        let run = RoutineRun(routineId: routine.id, name: routine.name, startedAt: started, maxMinutes: routine.maxMinutes,
                             notifies: routine.notifies, signal: pending.signal)
        (rt.run, rt.runEnding, rt.turnChain, rt.turnTask) = (run, nil, pending.chain, nil)
        record(.routineRun(run), rt)
        let text = routineTurnText(routine, run: routine.runs, startedAt: started, signal: pending.signal)
        if rt.bot.agent == .codex {
            rt.outbox.append(Outgoing(text: text, origin: .routine))
            deliverCodex(rt)
        } else {
            type(text, origin: .routine, into: rt)
        }
    }

    /// The run's turn ended (spec §4): its outcome goes on the routine and on the run's header in the chat.
    func runEnded(_ rt: BotRuntime, _ outcome: RoutineOutcome) {
        guard var run = rt.run else { return }
        (rt.run, rt.runEnding) = (nil, nil)
        run.outcome = outcome
        var routines = store.routines(rt.bot.projectId)
        if let i = routines.firstIndex(where: { $0.id == run.routineId }) {
            routines[i].lastOutcome = outcome
            save(routines, rt.bot.projectId)
            push(.routinesChanged(projectId: rt.bot.projectId, routines: routines))
        }
        record(.routineRun(run), rt)
    }

    /// A run now, as "Run now" and `run_routine` ask (spec §4–5): one waiting run at most.
    func queueRun(_ id: UUID, in project: UUID, chain: Int = 0) {
        var routines = store.routines(project)
        guard let i = routines.firstIndex(where: { $0.id == id }), routines[i].pending == nil else { return }
        routines[i].pending = PendingRun(dueAt: now(), chain: chain)
        save(routines, project)
        push(.routinesChanged(projectId: project, routines: routines))
        bots[routines[i].botId].map(deliverMail)
    }

    /// A bot archived (spec §4): its routines go.
    func routinesArchived(_ bot: Bot) {
        let routines = store.routines(bot.projectId).filter { $0.botId != bot.id }
        guard routines.count != store.routines(bot.projectId).count else { return }
        save(routines, bot.projectId)
        push(.routinesChanged(projectId: bot.projectId, routines: routines))
    }

    /// The engine's own moves (a run's start, its outcome, the sweep) go on when the file cannot be written: the log
    /// says so, like the mail (spec §9).
    func save(_ routines: [Routine], _ project: UUID) {
        do { try store.save(routines, project: project) } catch {
            store.keep(routines, project: project)
            log("routines.json not written: \(error); kept in memory, a restart may redo one run")
        }
    }

    // MARK: - The sheet (spec §4)

    /// The sheet's Save: a new routine, or a changed one whose run state (creator, creation, runs, last run, waiting
    /// run) stays the engine's. Turned off, it drops its waiting run.
    func saveRoutine(_ given: Routine) throws {
        guard let rt = bots[given.botId], rt.bot.archivedAt == nil else { throw Refusal("Unknown bot") }
        var routines = store.routines(rt.bot.projectId)
        var routine = given
        if let old = routines.first(where: { $0.id == given.id }) {
            (routine.createdBy, routine.createdAt, routine.runs) = (old.createdBy, old.createdAt, old.runs)
            (routine.lastRunAt, routine.lastOutcome, routine.pending) = (old.lastRunAt, old.lastOutcome, old.pending)
        } else {
            (routine.createdBy, routine.createdAt, routine.pending, routine.runs) = (.user, now(), nil, 0)
            (routine.lastRunAt, routine.lastOutcome) = (nil, nil)
        }
        if !routine.enabled { routine.pending = nil }
        if let problem = routineProblem(routine, among: routines, now: now()) { throw Refusal(problem) }
        if let i = routines.firstIndex(where: { $0.id == routine.id }) { routines[i] = routine } else { routines.append(routine) }
        try store.save(routines, project: rt.bot.projectId)
        push(.routinesChanged(projectId: rt.bot.projectId, routines: routines))
    }

    func deleteRoutine(_ id: UUID) throws {
        let (project, routines) = try located(id)
        try store.save(routines.filter { $0.id != id }, project: project)
        push(.routinesChanged(projectId: project, routines: routines.filter { $0.id != id }))
    }

    func runRoutineNow(_ id: UUID) throws {
        let (project, _) = try located(id)
        queueRun(id, in: project)
    }

    /// The project of a routine the app names, and that project's routines.
    private func located(_ id: UUID) throws -> (project: UUID, routines: [Routine]) {
        for project in store.projects {
            let routines = store.routines(project.id)
            if routines.contains(where: { $0.id == id }) { return (project.id, routines) }
        }
        throw Refusal("Unknown routine")
    }

    // MARK: - Tools (spec §4–5)

    /// `create_routine`: one trigger among the five forms, the bot's own name space, at most 20.
    func createRoutine(_ a: JSONValue, from rt: BotRuntime) throws -> String {
        guard let name = a["name"]?.string, let prompt = a["prompt"]?.string else {
            throw MailError("create_routine needs name and prompt")
        }
        var routines = store.routines(rt.bot.projectId)
        if let full = routineLimitError(count: routines.filter { $0.botId == rt.bot.id }.count) { throw MailError(full) }
        let routine = Routine(botId: rt.bot.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              trigger: try trigger(in: a), prompt: prompt,
                              maxMinutes: try number(a["max_minutes"], "max_minutes") ?? 30,
                              notifies: a["notify"]?.bool ?? true, createdBy: .bot, createdAt: now())
        if let problem = routineProblem(routine, among: routines, now: now()) { throw MailError(problem) }
        routines.append(routine)
        try store.save(routines, project: rt.bot.projectId)
        push(.routinesChanged(projectId: rt.bot.projectId, routines: routines))
        if case let .signal(signal) = routine.trigger { return "Routine «\(routine.name)» created, runs on the signal «\(signal)»" }
        let next = nextRun(of: routine, notBefore: routineFloor).map { mailDate($0) } ?? "never"
        return "Routine «\(routine.name)» created, next run \(next)"
    }

    /// The one trigger of a `create_routine` call (spec §4): every_minutes, daily_at, weekdays_at, signal or cron.
    private func trigger(in a: JSONValue) throws -> RoutineTrigger {
        var found: [RoutineTrigger] = []
        if let m = try number(a["every_minutes"], "every_minutes") { found.append(.every(minutes: m)) }
        if let t = a["daily_at"], t != .null {
            guard let (h, m) = t.string.flatMap(clockTime) else { throw MailError("daily_at must be HH:MM") }
            found.append(.dailyAt(hour: h, minute: m))
        }
        if let w = a["weekdays_at"], w != .null {
            guard let list = w["days"]?.array, case let days = list.compactMap(\.int), days.count == list.count,
                  let (h, m) = w["time"]?.string.flatMap(clockTime) else {
                throw MailError("weekdays_at needs days (1 = Monday … 7 = Sunday) and time \"HH:MM\"")
            }
            found.append(.weekdaysAt(days: Set(days), hour: h, minute: m))
        }
        if let s = a["signal"], s != .null { found.append(.signal(name: try text(s, "signal"))) }
        if let c = a["cron"], c != .null { found.append(.cron(expression: try text(c, "cron"))) }
        guard found.count == 1 else { throw MailError("give exactly one of every_minutes, daily_at, weekdays_at, signal or cron") }
        return found[0]
    }

    /// A trigger field that must be text: a number or a list is refused by name, never coerced.
    private func text(_ v: JSONValue, _ field: String) throws -> String {
        guard let s = v.string else { throw MailError("\(field) must be text") }
        return s
    }

    func listRoutines(for rt: BotRuntime) -> String {
        routinesText(store.routines(rt.bot.projectId).filter { $0.botId == rt.bot.id }) { nextRun(of: $0, notBefore: routineFloor) }
    }

    func setRoutineEnabled(_ a: JSONValue, from rt: BotRuntime) throws -> String {
        guard let enabled = a["enabled"]?.bool else { throw MailError("set_routine_enabled needs name and enabled") }
        var routines = store.routines(rt.bot.projectId)
        let i = try own(a["name"], in: routines, rt)
        routines[i].enabled = enabled
        if !enabled { routines[i].pending = nil }          // a routine turned off runs no more (spec §4)
        try store.save(routines, project: rt.bot.projectId)
        push(.routinesChanged(projectId: rt.bot.projectId, routines: routines))
        return "Routine «\(routines[i].name)» is now \(enabled ? "on" : "off")"
    }

    func deleteRoutine(_ a: JSONValue, from rt: BotRuntime) throws -> String {
        var routines = store.routines(rt.bot.projectId)
        let gone = routines.remove(at: try own(a["name"], in: routines, rt))
        try store.save(routines, project: rt.bot.projectId)
        push(.routinesChanged(projectId: rt.bot.projectId, routines: routines))
        return "Routine «\(gone.name)» deleted"
    }

    /// `run_routine`: a run once this turn ends (the bot calling is not free).
    func runRoutine(_ a: JSONValue, from rt: BotRuntime) throws -> String {
        let routines = store.routines(rt.bot.projectId)
        let routine = routines[try own(a["name"], in: routines, rt)]
        guard rt.turnChain < RoutineRules.maxSignalChain else { throw MailError("routine chain too long") }
        queueRun(routine.id, in: rt.bot.projectId, chain: rt.turnChain + 1)
        return "Routine «\(routine.name)» will run as soon as you are free"
    }

    /// The caller's routine called `name`: another bot's is "not your routine" (spec §9).
    private func own(_ name: JSONValue?, in routines: [Routine], _ rt: BotRuntime) throws -> Int {
        guard let name = name?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw MailError("which routine? give its name")
        }
        let same = routines.indices.filter { routines[$0].name.caseInsensitiveCompare(name) == .orderedSame }
        guard let i = same.first(where: { routines[$0].botId == rt.bot.id }) else {
            throw MailError(same.isEmpty ? "you have no routine called \(name)" : "not your routine")
        }
        return i
    }
    /// `emit_signal` (spec §5): every routine of the project on that signal gets a run, one at most; a run a signal
    /// started counts the chain, and a turn at 4 may not go on.
    func emitSignal(_ a: JSONValue, from rt: BotRuntime) throws -> String {
        guard let name = a["name"]?.string else { throw MailError("emit_signal needs name") }
        if let problem = signalNameProblem(name) { throw MailError(problem) }
        let text = a["text"]?.string
        if let text, text.utf8.count > RoutineRules.maxSignalBytes { throw MailError("the text is longer than 4 KB") }
        guard rt.turnChain < RoutineRules.maxSignalChain else { throw MailError("signal chain too long") }
        var routines = store.routines(rt.bot.projectId)
        var hit = 0
        for i in routines.indices where routines[i].enabled {
            guard case let .signal(wanted) = routines[i].trigger, wanted.caseInsensitiveCompare(name) == .orderedSame else { continue }
            hit += 1
            if routines[i].pending == nil {
                routines[i].pending = PendingRun(dueAt: now(), signal: RunSignal(name: name, text: text, from: rt.bot.name,
                                                                                 chain: rt.turnChain + 1),
                                                     chain: rt.turnChain + 1)
            }
        }
        if hit > 0 {
            try store.save(routines, project: rt.bot.projectId)
            push(.routinesChanged(projectId: rt.bot.projectId, routines: routines))
            deliverMail(in: rt.bot.projectId)
        }
        return "Signal «\(name)» sent to \(hit) routine\(hit == 1 ? "" : "s")"
    }

}
