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
