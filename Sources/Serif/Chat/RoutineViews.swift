import SwiftUI
import SerifCore

/// A routine's run in the chat (spec §4 of 0.6): "Routine «Rassegna» · 09:00", with the signal that started it, and its
/// outcome once the engine records it again ("finished", "stopped after 30 min", "crashed", "interrupted").
struct RoutineRunLine: View {
    let run: RoutineRun

    var body: some View {
        Text(text).font(.system(size: Theme.Size.body)).foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }

    private var text: String {
        let time = run.startedAt.formatted(date: .omitted, time: .shortened)
        var s = String(localized: "Routine «\(run.name)» · \(time)")
        if let signal = run.signal { s += " · " + String(localized: "signal «\(signal.name)» from \(signal.from)") }
        if let outcome = run.outcome { s += " · " + outcomeLabel(outcome, maxMinutes: run.maxMinutes) }
        return s
    }
}

/// A run's outcome in the app's language; nil is a run still on.
func outcomeLabel(_ outcome: RoutineOutcome?, maxMinutes: Int) -> String {
    switch outcome {
    case .done?: String(localized: "Routine.done")
    case .stopped?: String(localized: "stopped after \(maxMinutes) min")
    case .failed?: String(localized: "Routine.failed")
    case .interrupted?: String(localized: "Routine.interrupted")
    case nil: String(localized: "Routine.running")
    }
}

/// A trigger in the app's language: "every 30 minutes", "every day at 09:00", "on Mon, Fri at 09:00", "on the signal
/// «build-done»"; a cron expression as it is.
func triggerLabel(_ t: RoutineTrigger) -> String {
    switch t {
    case .every(let m):
        return m == 60 ? String(localized: "every hour")
            : m % 60 == 0 ? String(localized: "every \(m / 60) hours") : String(localized: "every \(m) minutes")
    case .dailyAt(let h, let m): return String(localized: "every day at \(clockText(h, m))")
    case .weekdaysAt(let days, let h, let m):
        // The Mac's own short day names, which start on Sunday; ours start on Monday.
        let symbols = Calendar.current.shortWeekdaySymbols
        return String(localized: "on \(days.sorted().map { symbols[$0 % 7] }.joined(separator: ", ")) at \(clockText(h, m))")
    case .signal(let name): return String(localized: "on the signal «\(name)»")
    case .cron(let e): return "cron \(e)"
    }
}

/// One routine in the bot's settings (spec §4): name, when, on/off, last and next run, and Run now / Edit / Delete.
struct RoutineRow: View {
    let routine: Routine
    let client: EngineClient
    let edit: () -> Void
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(routine.name).font(.system(size: Theme.Size.body, weight: .medium))
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { routine.enabled }, set: { on in
                    var changed = routine; changed.enabled = on
                    act { try await client.saveRoutine(changed) }
                })).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Text(triggerLabel(routine.trigger)).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
            Text(status).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                CardButton(title: String(localized: "Run now")) { act { try await client.runRoutine(routine.id) } }
                CardButton(title: String(localized: "Edit"), style: .ghost, action: edit)
                CardButton(title: String(localized: "Delete"), style: .ghost) { confirmDelete = true }
                    .confirmationDialog(String(localized: "Delete the routine «\(routine.name)»?"),
                                        isPresented: $confirmDelete) {
                        Button(String(localized: "Delete"), role: .destructive) {
                            act { try await client.deleteRoutine(routine.id) }
                        }
                    }
                if let error { Text(error).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.red) }
            }
        }
        .padding(.vertical, 4)
    }

    private var status: String {
        var parts: [String] = []
        if let last = routine.lastRunAt {
            parts.append(String(localized: "last run \(last.formatted(date: .abbreviated, time: .shortened)) · \(outcomeLabel(routine.lastOutcome, maxMinutes: routine.maxMinutes))"))
        }
        if routine.pending != nil { parts.append(String(localized: "a run is waiting")) }
        else if routine.enabled, let next = nextRun(of: routine, notBefore: Date()) {
            parts.append(String(localized: "next run \(next.formatted(date: .abbreviated, time: .shortened))"))
        }
        return parts.isEmpty ? String(localized: "never ran") : parts.joined(separator: " · ")
    }

    private func act(_ action: @escaping () async throws -> Void) {
        error = nil
        Task { do { try await action() } catch { self.error = error.localizedDescription } }
    }
}
