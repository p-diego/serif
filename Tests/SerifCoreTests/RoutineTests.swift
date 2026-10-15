import XCTest
@testable import SerifCore

final class RoutineTests: XCTestCase {
    private let bot = UUID()
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    private func routine(_ trigger: RoutineTrigger, createdAt: Date, lastRunAt: Date? = nil) -> Routine {
        Routine(botId: bot, name: "R", trigger: trigger, prompt: "Do it", createdBy: .user, createdAt: createdAt, lastRunAt: lastRunAt)
    }

    // MARK: - Next run (spec §4)

    func testEveryKeepsItsCadenceFromTheLastRun() {
        // Thursday 15 Oct 2026, 09:00 local.
        let t0 = date(2026, 10, 15, 9, 0)
        XCTAssertEqual(nextRun(of: routine(.every(minutes: 30), createdAt: t0), calendar: cal), date(2026, 10, 15, 9, 30))
        XCTAssertEqual(nextRun(of: routine(.every(minutes: 30), createdAt: t0, lastRunAt: date(2026, 10, 15, 10, 7)), calendar: cal),
                       date(2026, 10, 15, 10, 37))
        // The engine was off: the next one after its start, on the same cadence; nothing before it is made up.
        XCTAssertEqual(nextRun(of: routine(.every(minutes: 30), createdAt: t0), notBefore: date(2026, 10, 15, 11, 10), calendar: cal),
                       date(2026, 10, 15, 11, 30))
        XCTAssertEqual(nextRun(of: routine(.every(minutes: 30), createdAt: t0), notBefore: date(2026, 10, 15, 8, 0), calendar: cal),
                       date(2026, 10, 15, 9, 30))             // a floor in the past changes nothing
    }

    func testDailyAndWeekdaysTakeTheNextOccurrenceInLocalTime() {
        let t0 = date(2026, 10, 15, 9, 0)                       // Thursday
        XCTAssertEqual(nextRun(of: routine(.dailyAt(hour: 9, minute: 0), createdAt: t0), calendar: cal), date(2026, 10, 16, 9, 0))
        XCTAssertEqual(nextRun(of: routine(.dailyAt(hour: 18, minute: 30), createdAt: t0), calendar: cal), date(2026, 10, 15, 18, 30))
        XCTAssertEqual(nextRun(of: routine(.dailyAt(hour: 9, minute: 0), createdAt: t0, lastRunAt: date(2026, 10, 15, 9, 0)), calendar: cal),
                       date(2026, 10, 16, 9, 0))
        // Mon, Wed, Fri (1 = Monday): from Thursday 09:00 the next is Friday; from Friday 10:00, Monday.
        let mwf = RoutineTrigger.weekdaysAt(days: [1, 3, 5], hour: 9, minute: 0)
        XCTAssertEqual(nextRun(of: routine(mwf, createdAt: t0), calendar: cal), date(2026, 10, 16, 9, 0))
        XCTAssertEqual(nextRun(of: routine(mwf, createdAt: date(2026, 10, 16, 10, 0)), calendar: cal), date(2026, 10, 19, 9, 0))
        // Sunday is 7.
        XCTAssertEqual(nextRun(of: routine(.weekdaysAt(days: [7], hour: 8, minute: 0), createdAt: t0), calendar: cal), date(2026, 10, 18, 8, 0))
        XCTAssertNil(nextRun(of: routine(.signal(name: "go"), createdAt: t0), calendar: cal))
    }

    func testClockChangesMoveAMissingTimeOnAndKeepOneAfterwards() {
        // Europe/Rome springs forward on 29 Mar 2026: 02:30 does not exist, the run moves to 03:00.
        let before = date(2026, 3, 28, 12, 0)
        let spring = nextRun(of: routine(.dailyAt(hour: 2, minute: 30), createdAt: before), calendar: cal)
        XCTAssertEqual(spring, date(2026, 3, 29, 3, 0))
        XCTAssertEqual(spring.map { cal.dateComponents([.day, .hour, .minute], from: $0) },
                       DateComponents(day: 29, hour: 3, minute: 0))
        // Falls back on 25 Oct 2026: 09:00 is still one run a day, 25 hours after the day before.
        let autumn = routine(.dailyAt(hour: 9, minute: 0), createdAt: date(2026, 10, 24, 9, 0))
        let next = nextRun(of: autumn, calendar: cal)
        XCTAssertEqual(next, date(2026, 10, 25, 9, 0))
        XCTAssertEqual(next!.timeIntervalSince(date(2026, 10, 24, 9, 0)), 25 * 3600)
    }

    func testCronFiveFields() throws {
        let t0 = date(2026, 10, 15, 9, 0)                       // Thursday
        func next(_ e: String, after: Date? = nil) -> Date? {
            nextRun(of: routine(.cron(expression: e), createdAt: after ?? t0), calendar: cal)
        }
        XCTAssertEqual(next("*/15 * * * *"), date(2026, 10, 15, 9, 15))
        XCTAssertEqual(next("0 9 * * 1-5"), date(2026, 10, 16, 9, 0))             // weekdays: Friday
        XCTAssertEqual(next("0 9 * * 1-5", after: date(2026, 10, 16, 9, 0)), date(2026, 10, 19, 9, 0))   // then Monday
        XCTAssertEqual(next("30 2 1 * *"), date(2026, 11, 1, 2, 30))               // the first of the month
        XCTAssertEqual(next("0 0 * * 0"), date(2026, 10, 18, 0, 0))                // 0 is Sunday
        XCTAssertEqual(next("0 0 * * 7"), date(2026, 10, 18, 0, 0))                // so is 7
        XCTAssertEqual(next("0 12 15 * 1"), date(2026, 10, 15, 12, 0))             // day OR weekday, as cron has it
        XCTAssertEqual(next("0 12 15 * 1", after: date(2026, 10, 15, 12, 0)), date(2026, 10, 19, 12, 0))
        XCTAssertEqual(next("5,35 8-10 * * *"), date(2026, 10, 15, 9, 5))
        XCTAssertNil(next("0 0 31 2 *"))                                           // never comes
        for bad in ["0 9 * *", "60 * * * *", "* 24 * * *", "a b c d e", "*/0 * * * *", "9-3 * * * *", ""] {
            XCTAssertNil(CronSchedule(bad), bad)
        }
        XCTAssertNotNil(CronSchedule("0 9 * * 1-5"))
    }

    // MARK: - Rules (spec §4–5)

    func testRules() {
        let t0 = date(2026, 10, 15, 9, 0)
        let ok = routine(.every(minutes: 5), createdAt: t0)
        XCTAssertNil(routineProblem(ok, among: []))
        var other = ok; other.id = UUID(); other.name = " r "
        XCTAssertEqual(routineProblem(ok, among: [other]), "you already have a routine called R")
        var elsewhere = other; elsewhere.botId = UUID()
        XCTAssertNil(routineProblem(ok, among: [elsewhere]))                        // names are per bot
        XCTAssertNil(routineProblem(ok, among: [ok]))                               // itself, being changed
        var bad = ok
        bad.name = " "; XCTAssertEqual(routineProblem(bad, among: []), "the routine needs a name")
        bad = ok; bad.prompt = "\n"; XCTAssertEqual(routineProblem(bad, among: []), "the routine needs a prompt")
        bad = ok; bad.prompt = String(repeating: "x", count: 16_385); XCTAssertEqual(routineProblem(bad, among: []), "the prompt is longer than 16 KB")
        bad = ok; bad.prompt = String(repeating: "x", count: 16_384); XCTAssertNil(routineProblem(bad, among: []))
        for minutes in [0, 481] { bad = ok; bad.maxMinutes = minutes; XCTAssertEqual(routineProblem(bad, among: []), "max_minutes must be between 1 and 480") }
        bad = ok; bad.maxMinutes = 480; XCTAssertNil(routineProblem(bad, among: []))
        XCTAssertEqual(triggerProblem(.every(minutes: 4)), "every_minutes must be at least 5")
        XCTAssertEqual(triggerProblem(.dailyAt(hour: 24, minute: 0)), "the time must be HH:MM, from 00:00 to 23:59")
        XCTAssertEqual(triggerProblem(.weekdaysAt(days: [], hour: 9, minute: 0)), "days must be between 1 (Monday) and 7 (Sunday)")
        XCTAssertEqual(triggerProblem(.weekdaysAt(days: [0, 1], hour: 9, minute: 0)), "days must be between 1 (Monday) and 7 (Sunday)")
        XCTAssertEqual(triggerProblem(.weekdaysAt(days: [1], hour: 9, minute: 60)), "the time must be HH:MM, from 00:00 to 23:59")
        XCTAssertEqual(triggerProblem(.signal(name: "build done")), "the signal name must be 1 to 64 characters with no spaces")
        XCTAssertEqual(triggerProblem(.signal(name: String(repeating: "a", count: 65))), "the signal name must be 1 to 64 characters with no spaces")
        XCTAssertNil(triggerProblem(.signal(name: String(repeating: "a", count: 64))))
        XCTAssertEqual(triggerProblem(.cron(expression: "* * *")), "cron must have five fields: minute hour day month weekday")
        XCTAssertNil(routineLimitError(count: 19))
        XCTAssertEqual(routineLimitError(count: 20), "you already have 20 routines: delete one first")
        XCTAssertEqual(clockTime("09:05").map { [$0.hour, $0.minute] }, [9, 5])
        XCTAssertEqual(clockTime(" 23:59 ").map { [$0.hour, $0.minute] }, [23, 59])
        for bad in ["9", "24:00", "09:60", "nine", "09:05:00"] { XCTAssertNil(clockTime(bad), bad) }
    }

    // MARK: - Texts (spec §4)

    func testTurnTextAndTriggerWords() {
        let utc = TimeZone(identifier: "UTC")!
        let started = Date(timeIntervalSince1970: 1_792_054_800)        // 15 Oct 2026, 09:00 UTC
        var r = routine(.dailyAt(hour: 9, minute: 0), createdAt: started)
        r.name = "Rassegna"; r.prompt = "Read the news and write a summary."
        XCTAssertEqual(routineTurnText(r, run: 12, startedAt: started, signal: nil, timeZone: utc),
                       "Routine «Rassegna» (run of 15 Oct 2026, 09:00; this is run #12). Stay within this job and finish within "
                       + "30 minutes.\n\nRead the news and write a summary.")
        let signal = RunSignal(name: "build-done", text: "v0.6 built", from: "Cody", chain: 1)
        XCTAssertEqual(routineTurnText(r, run: 1, startedAt: started, signal: signal, timeZone: utc),
                       "Routine «Rassegna» (run of 15 Oct 2026, 09:00; this is run #1). Stay within this job and finish within "
                       + "30 minutes.\n\nStarted by the signal «build-done» from Cody: v0.6 built\n\nRead the news and write a summary.")
        let silent = RunSignal(name: "go", text: nil, from: "Cody", chain: 2)
        XCTAssertTrue(routineTurnText(r, run: 1, startedAt: started, signal: silent, timeZone: utc)
            .contains("\n\nStarted by the signal «go» from Cody\n\n"))
        XCTAssertEqual(triggerText(.every(minutes: 30)), "every 30 minutes")
        XCTAssertEqual(triggerText(.every(minutes: 60)), "every hour")
        XCTAssertEqual(triggerText(.every(minutes: 180)), "every 3 hours")
        XCTAssertEqual(triggerText(.dailyAt(hour: 9, minute: 5)), "daily at 09:05")
        XCTAssertEqual(triggerText(.weekdaysAt(days: [5, 1], hour: 18, minute: 0)), "on Mon, Fri at 18:00")
        XCTAssertEqual(triggerText(.signal(name: "build-done")), "on the signal «build-done»")
        XCTAssertEqual(triggerText(.cron(expression: "0 9 * * 1-5")), "cron 0 9 * * 1-5")
    }

    func testListText() {
        let utc = TimeZone(identifier: "UTC")!
        let t0 = Date(timeIntervalSince1970: 1_792_054_800)             // 15 Oct 2026, 09:00 UTC
        var daily = routine(.dailyAt(hour: 9, minute: 0), createdAt: t0, lastRunAt: t0)
        daily.name = "Rassegna"; daily.lastOutcome = .done
        var signal = routine(.signal(name: "build-done"), createdAt: t0)
        signal.name = "Deploy"; signal.enabled = false; signal.maxMinutes = 10
        var pending = routine(.every(minutes: 5), createdAt: t0, lastRunAt: t0)
        pending.name = "Tick"; pending.pending = PendingRun(dueAt: t0)
        XCTAssertEqual(routinesText([daily, signal, pending], next: { $0.name == "Rassegna" ? t0.addingTimeInterval(86_400) : nil },
                                    timeZone: utc), """
            Your routines:
            - «Rassegna» (daily at 09:00, on, up to 30 min): next run 16 Oct 2026, 09:00; last run 15 Oct 2026, 09:00, done
            - «Deploy» (on the signal «build-done», off, up to 10 min): never ran
            - «Tick» (every 5 minutes, on, up to 30 min): a run is waiting for you to be free; last run 15 Oct 2026, 09:00, running
            """)
        XCTAssertEqual(routinesText([], next: { _ in nil }), "You have no routines.")
    }

    // MARK: - Codable (spec §10)

    func testAnOlderRoutineDecodesWithTheDefaults() throws {
        let json = #"""
        {"id":"11111111-1111-4111-8111-111111111111","botId":"22222222-2222-4222-8222-222222222222","name":"R",
         "trigger":{"every":{"minutes":30}},"prompt":"Do it"}
        """#
        let r = try protocolDecoder().decode(Routine.self, from: Data(json.utf8))
        XCTAssertEqual([r.maxMinutes, r.runs], [30, 0])
        XCTAssertTrue(r.notifies && r.enabled)
        XCTAssertEqual(r.createdBy, .user)
        XCTAssertNil(r.lastRunAt); XCTAssertNil(r.lastOutcome); XCTAssertNil(r.pending)
        // Every trigger and the run state survive the protocol.
        let triggers: [RoutineTrigger] = [.every(minutes: 5), .dailyAt(hour: 9, minute: 0), .weekdaysAt(days: [1, 7], hour: 18, minute: 30),
                                          .signal(name: "go"), .cron(expression: "0 9 * * 1-5")]
        for trigger in triggers {
            var full = routine(trigger, createdAt: Date(timeIntervalSince1970: 1_792_054_800.125), lastRunAt: Date(timeIntervalSince1970: 1_792_058_400))
            full.lastOutcome = .stopped; full.runs = 3; full.createdBy = .bot
            full.pending = PendingRun(dueAt: Date(timeIntervalSince1970: 1_792_062_000),
                                      signal: RunSignal(name: "go", text: "now", from: "Cody", chain: 2))
            let data = try protocolEncoder().encode(full)
            XCTAssertEqual(try protocolDecoder().decode(Routine.self, from: data), full)
        }
    }
}
