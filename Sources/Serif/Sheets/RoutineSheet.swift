import SwiftUI
import SerifCore

/// A routine of a bot, new or changed (spec §4 of 0.6): name, when (every N, daily, chosen weekdays, a signal; a cron
/// expression set by the bot is shown as it is), what to do, the time limit, "Tell me when it finishes".
struct RoutineSheet: View {
    let client: EngineClient
    let bot: Bot
    let editing: Routine?
    let close: () -> Void

    private enum When: Hashable { case every, daily, weekdays, signal, cron }
    @State private var name: String
    @State private var when: When
    @State private var everyCount: Int
    @State private var everyHours: Bool
    @State private var time: Date
    @State private var days: Set<Int>
    @State private var signal: String
    @State private var cron: String
    @State private var prompt: String
    @State private var maxMinutes: Int
    @State private var notifies: Bool
    @State private var busy = false
    @State private var error: String?

    init(client: EngineClient, bot: Bot, editing: Routine?, close: @escaping () -> Void) {
        self.client = client; self.bot = bot; self.editing = editing; self.close = close
        _name = State(initialValue: editing?.name ?? "")
        _prompt = State(initialValue: editing?.prompt ?? "")
        _maxMinutes = State(initialValue: editing?.maxMinutes ?? 30)
        _notifies = State(initialValue: editing?.notifies ?? true)
        var when = When.every, count = 30, hours = false, hour = 9, minute = 0, days: Set<Int> = [1, 2, 3, 4, 5]
        var signal = "", cron = ""
        switch editing?.trigger {
        case .every(let m)?: (count, hours) = m % 60 == 0 ? (m / 60, true) : (m, false)
        case .dailyAt(let h, let m)?: (when, hour, minute) = (.daily, h, m)
        case .weekdaysAt(let d, let h, let m)?: (when, days, hour, minute) = (.weekdays, d, h, m)
        case .signal(let s)?: (when, signal) = (.signal, s)
        case .cron(let e)?: (when, cron) = (.cron, e)
        case nil: break
        }
        _when = State(initialValue: when); _everyCount = State(initialValue: count); _everyHours = State(initialValue: hours)
        _time = State(initialValue: Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)) ?? Date())
        _days = State(initialValue: days); _signal = State(initialValue: signal); _cron = State(initialValue: cron)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SheetFrame(title: editing == nil ? String(localized: "New routine") : String(localized: "Routine"),
                   primary: String(localized: "Save"), canSubmit: canSave, busy: busy, error: error, submit: save, cancel: close) {
            FieldGroup(label: String(localized: "Name")) {
                TextField(String(localized: "Routine name"), text: $name).textFieldStyle(.plain).font(.system(size: Theme.Size.body))
            }
            FieldGroup(label: String(localized: "When")) {
                if when == .cron {
                    Text(cron).font(.system(size: Theme.Size.body, design: .monospaced))
                    Text(String(localized: "Set by the bot as a cron expression: delete the routine and make it again to change it."))
                        .font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("", selection: $when) {
                        Text(String(localized: "Every")).tag(When.every)
                        Text(String(localized: "Daily")).tag(When.daily)
                        Text(String(localized: "Weekdays")).tag(When.weekdays)
                        Text(String(localized: "Signal")).tag(When.signal)
                    }.pickerStyle(.segmented).labelsHidden()
                    switch when {
                    case .every:
                        HStack {
                            TextField("", value: $everyCount, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
                            Picker("", selection: $everyHours) {
                                Text(String(localized: "minutes")).tag(false)
                                Text(String(localized: "hours")).tag(true)
                            }.labelsHidden().frame(width: 110)
                        }
                    case .daily:
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
                    case .weekdays:
                        HStack(spacing: 6) {
                            ForEach(1...7, id: \.self) { day in
                                let symbols = Calendar.current.veryShortWeekdaySymbols      // Sunday first
                                Toggle(symbols[day % 7], isOn: Binding(get: { days.contains(day) },
                                                                        set: { if $0 { days.insert(day) } else { days.remove(day) } }))
                                    .toggleStyle(.button)
                            }
                        }
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
                    case .signal:
                        TextField(String(localized: "Signal name, e.g. build-done"), text: $signal)
                            .textFieldStyle(.plain).font(.system(size: Theme.Size.body))
                        Text(String(localized: "A bot of the project announces it with its tools; every routine on that signal runs."))
                            .font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .cron:
                        EmptyView()
                    }
                }
            }
            FieldGroup(label: String(localized: "What to do")) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $prompt).scrollContentBackground(.hidden).font(.system(size: Theme.Size.body))
                        .frame(minHeight: 6 * 18)
                    if prompt.isEmpty {
                        Text(String(localized: "The whole job, as the bot runs it alone")).foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
            }
            FieldGroup(label: String(localized: "Time limit")) {
                HStack {
                    TextField("", value: $maxMinutes, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
                    Text(String(localized: "minutes"))
                }
                Text(String(localized: "A run longer than this is stopped, as with Stop."))
                    .font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
            }
            Toggle(String(localized: "Tell me when it finishes"), isOn: $notifies).toggleStyle(.switch)
        }
        .frame(width: 480).frame(minHeight: 360, idealHeight: sheetHeight(720), maxHeight: sheetHeight(720))
    }

    private var trigger: RoutineTrigger {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        switch when {
        case .every: return .every(minutes: everyCount * (everyHours ? 60 : 1))
        case .daily: return .dailyAt(hour: c.hour ?? 0, minute: c.minute ?? 0)
        case .weekdays: return .weekdaysAt(days: days, hour: c.hour ?? 0, minute: c.minute ?? 0)
        case .signal: return .signal(name: signal.trimmingCharacters(in: .whitespaces))
        case .cron: return .cron(expression: cron)
        }
    }

    /// The engine checks the rules (name, limits, trigger) and keeps the run state of a routine being changed.
    private func save() {
        var routine = editing ?? Routine(botId: bot.id, name: "", trigger: trigger, prompt: "", createdBy: .user)
        routine.name = name.trimmingCharacters(in: .whitespaces)
        (routine.trigger, routine.prompt, routine.maxMinutes, routine.notifies) = (trigger, prompt, maxMinutes, notifies)
        busy = true; error = nil
        Task {
            do { try await client.saveRoutine(routine); close() }
            catch { self.error = error.localizedDescription; busy = false }
        }
    }
}
