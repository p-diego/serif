import SwiftUI
import SerifCore

/// Localized text for what a working bot is doing.
func activityText(_ a: Activity) -> String {
    switch a {
    case .thinking: String(localized: "Thinking…")
    case .typing: String(localized: "Typing…")
    case .runningCommand(let c?): String(localized: "Running a command: \(c)")
    case .runningCommand(nil): String(localized: "Running a command…")
    case .reading(let f): String(localized: "Reading \(f)")
    case .editing(let f): String(localized: "Editing \(f)")
    case .searching: String(localized: "Searching…")
    case .browsing: String(localized: "Browsing the web…")
    case .delegating: String(localized: "Delegating to a sub-agent…")
    case .tool(let t): String(localized: "Using \(t)…")
    case .serif(let call): serifStatusText(call)
    }
}

/// What one of Serif's tools is doing, live (spec §9).
func serifStatusText(_ call: SerifToolCall) -> String {
    switch call {
    case .message(let to): String(localized: "Writing to \(to)…")
    case .completeTask(let n): String(localized: "Closing task #\(n)…")
    case .cancelTask(let n): String(localized: "Cancelling task #\(n)…")
    case .inbox: String(localized: "Checking its mail…")
    case .colleagues: String(localized: "Looking at its colleagues…")
    case .createBot(let name): String(localized: "Creating \(name)…")
    case .updateInstructions: String(localized: "Updating instructions…")
    case .archiveBot(let name): String(localized: "Archiving \(name)…")
    }
}

/// A step of Serif's tools in its group (spec §9): "Message to Milo", "Task #17 closed", "Colleagues", "Bot created:
/// Milo".
func serifStepTitle(_ call: SerifToolCall) -> String {
    switch call {
    case .message(let to): String(localized: "Message to \(to)")
    case .completeTask(let n): String(localized: "Task #\(n) closed")
    case .cancelTask(let n): String(localized: "Task #\(n) cancelled")
    case .inbox: String(localized: "Steps.inbox")
    case .colleagues: String(localized: "Colleagues")
    case .createBot(let name): String(localized: "Bot created: \(name)")
    case .updateInstructions: String(localized: "Instructions updated")
    case .archiveBot(let name): String(localized: "Bot archived: \(name)")
    }
}

/// Header text for a bot that is not simply ready.
func stateText(_ s: BotState) -> String? {
    switch s {
    case .ready: nil
    case .starting: String(localized: "Starting…")
    case .working(let a): activityText(a)
    case .waiting: String(localized: "Waiting for you")
    case .rateLimited: String(localized: "Limit reached")
    case .crashed where s.relaunching: String(localized: "Starting…")
    case .crashed(let r, _): String(localized: "Stopped: \(crashReasonText(r))")
    case .stopped: String(localized: "Stopped")
    }
}

/// Under the last item while the bot works: the living mascot and the activity.
struct LiveStatus: View {
    let summary: BotSummary
    let activity: Activity

    var body: some View {
        HStack(spacing: 10) {
            BotAvatar(summary: summary, size: 28, alive: true)
            Text(activityText(activity)).font(.system(size: Theme.Size.body)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
    }
}
