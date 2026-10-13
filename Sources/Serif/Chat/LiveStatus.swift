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
    case .crashed(let r, _): String(localized: "Stopped: \(r)")
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
