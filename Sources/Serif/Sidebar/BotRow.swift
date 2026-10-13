import SwiftUI
import AppKit
import SerifCore

/// Status dot on the mascot's top-right: red = unread, orange = waiting for you.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 12, height: 12)
            .overlay(Circle().stroke(Theme.sidebar, lineWidth: 2))
    }
}

/// A mascot at `size` pt: alive when the bot works or waits, otherwise a cached still image. Carries the status dot.
struct BotAvatar: View {
    let summary: BotSummary
    let size: CGFloat
    /// Always the living mascot (chat header, live status); otherwise only while the bot works or waits (spec §4.8).
    var alive = false

    var body: some View {
        let m = mood(for: summary.state, unread: summary.unread)
        let animated: Bool = alive || { switch summary.state { case .working, .waiting: true; default: false } }()
        Group {
            if animated {
                LiveMascot(face: summary.bot.face, mood: m, avatar: size)
                    .frame(width: size + 2 * LiveMascot.inset, height: size + 2 * LiveMascot.inset)
            } else { MascotImage(face: summary.bot.face, mood: m, size: size) }
        }
        .frame(width: size, height: size)    // the live view overflows this box by its inset (not clipped)
        .overlay(alignment: .topTrailing) {
            if case .waiting = summary.state { StatusDot(color: Theme.yellowSolid).offset(x: 3, y: -3) }
            else if summary.unread { StatusDot(color: Theme.redSolid).offset(x: 3, y: -3) }
        }
    }
}

/// Equatable on what it shows, so unchanged rows are not re-rendered when other bots (or transcripts) change.
struct BotRow: View, Equatable {
    let summary: BotSummary
    let selected: Bool
    var request: PendingRequest?    // what a waiting bot asks, for the preview
    let client: EngineClient

    static func == (a: BotRow, b: BotRow) -> Bool { a.summary == b.summary && a.selected == b.selected && a.request == b.request }

    private var preview: String {
        if case .waiting = summary.state, let request { return requestSummary(request).text }
        if let at = summary.state.retryAt, at <= Date() { return String(localized: "Starting…") }    // as in the header
        return rowPreview(summary).text
    }

    var body: some View {
        HStack(spacing: 10) {
            BotAvatar(summary: summary, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(summary.bot.name).font(.system(size: 15)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let at = summary.lastEvent?.at {
                        Text(rowTime(at, now: Date(), calendar: .current, yesterday: String(localized: "Yesterday")))
                            .font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
                    }
                }
                TimelineView(.explicit(summary.state.retryAt.map { [$0] } ?? [])) { _ in
                    Text(preview).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8).frame(height: 56)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(selected ? Theme.active : .clear))
        .contentShape(Rectangle())
        .onTapGesture { client.selectedBot = summary.bot.id }
        .contextMenu { BotMenu(summary: summary, client: client) }
    }
}

struct BotMenu: View {
    let summary: BotSummary
    let client: EngineClient

    var body: some View {
        let bot = summary.bot
        Button(bot.pinned ? String(localized: "Unpin") : String(localized: "Pin")) {
            var updated = bot; updated.pinned.toggle()
            Task { try? await client.updateBot(updated) }
        }
        Button(String(localized: "Mark as unread")) {}.disabled(true)    // the engine has no request for it yet
        Button(String(localized: "Restart")) { Task { try? await client.restart(bot: bot.id) } }
        Button(String(localized: "Bot settings…")) { client.showBotSettings(bot.id) }
        Divider()
        Button(String(localized: "Archive"), role: .destructive) {
            // Same confirmation as the settings sheet.
            let alert = NSAlert()
            alert.messageText = String(localized: "Archive this bot?")
            alert.informativeText = String(localized: "Its chat is kept, but it stops working.")
            alert.addButton(withTitle: String(localized: "Archive bot")).hasDestructiveAction = true
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                if client.selectedBot == bot.id { client.selectedBot = nil }
                Task { try? await client.archive(bot: bot.id) }
            }
        }
    }
}

extension RowPreview {
    var text: String {
        switch self {
        case .typing: String(localized: "Typing…")
        case .waiting(let summary): summary ?? String(localized: "Waiting for you")
        case .crashed(let reason): String(localized: "Stopped: \(crashReasonText(reason))")
        case .rateLimited: String(localized: "Limit reached")
        case .text(let text): text
        }
    }
}

extension RequestSummary {
    var text: String {
        switch self {
        case .command(let c): String(localized: "Wants to run: \(c)")
        case .file(let f): String(localized: "Wants to edit: \(f)")
        case .question(let q): String(localized: "Asks you: \(q)")
        case .plan: String(localized: "Plan to approve")
        case .tool(let t): String(localized: "Wants to use: \(t)")
        }
    }
}
