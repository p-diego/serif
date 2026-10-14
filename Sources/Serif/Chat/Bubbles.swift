import SwiftUI
import SerifCore

struct UserBubble: View {
    let text: String
    let origin: MessageOrigin
    var pending = false
    let maxWidth: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(text).font(.system(size: Theme.Size.body)).foregroundStyle(Theme.userBubbleText)
                .textSelection(.enabled)
                .padding(.vertical, 12).padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous).fill(Theme.userBubble))
                .overlay(alignment: .bottomLeading) {
                    // 👍: the bot has taken the message (its userMessage arrived).
                    if origin == .chat && !pending {
                        Text("👍").font(.system(size: 13)).frame(width: 26, height: 26)
                            .background(Circle().fill(Theme.botBubble))
                            .overlay(Circle().stroke(Theme.pane, lineWidth: 2))
                            .offset(x: -4, y: 14)
                    }
                }
            if origin == .terminal {
                Text("from the terminal").font(.system(size: Theme.Size.caption)).foregroundStyle(Theme.textTertiary)
            }
        }
        .opacity(pending ? 0.55 : 1)
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct AssistantBubble: View {
    let text: String
    let maxWidth: CGFloat

    var body: some View {
        MarkdownText(text: text)
            .textSelection(.enabled)
            .padding(.vertical, 12).padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous).fill(Theme.botBubble))
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TimestampLine: View {
    let at: Date
    var body: some View {
        Text(Self.text(at)).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
    }

    /// "11:44 PM", "Yesterday 11:44 PM", or "Oct 3 11:44 PM" (current locale).
    static func text(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDate(d, inSameDayAs: now) { return time }
        if cal.isDate(d, inSameDayAs: cal.date(byAdding: .day, value: -1, to: now) ?? now) {
            return String(localized: "Yesterday") + " " + time
        }
        return d.formatted(.dateTime.month(.abbreviated).day()) + " " + time
    }
}

struct SystemLine: View {
    let note: SystemNote
    let botName: String
    var body: some View {
        Text(text).font(.system(size: Theme.Size.body)).foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }

    private var text: String {
        switch note {
        case .botCreated: String(localized: "Bot created")
        case .resumed: String(localized: "Resumed after the restart")
        case .newConversation: String(localized: "New conversation (resuming failed)")
        case .compacted: String(localized: "Conversation compacted")
        case .interrupted: String(localized: "Interrupted")
        case .introductionRequested: String(localized: "Serif asked \(botName) to introduce itself")
        case .linkedFolderMissing(let p): String(localized: "The linked folder is missing: \(p)")
        case .crashed(let r): String(localized: "Stopped: \(crashReasonText(r))")
        case .messageMayNotHaveArrived(let t): String(localized: "This message may not have reached Codex: \(t)")
        }
    }
}

/// "● Done" and friends: padding 2/8, dot 6, text 13 medium.
struct StatusPill: View {
    enum Kind { case done, failed, running, waiting, neutral }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            if kind == .running { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 8, height: 8) }
            else { Circle().fill(fg).frame(width: 6, height: 6) }
            Text(text).font(.system(size: Theme.Size.small, weight: .medium))
        }
        .foregroundStyle(fg).padding(.vertical, 2).padding(.horizontal, 8)
        .background(Capsule().fill(bg))
    }
    private var fg: Color { switch kind { case .done: Theme.green; case .failed: Theme.red; case .waiting: Theme.yellow; case .running, .neutral: Theme.textSecondary } }
    private var bg: Color { switch kind { case .done: Theme.greenTint; case .failed: Theme.redTint; case .waiting: Theme.yellowTint; case .running, .neutral: Theme.fillSecondary } }
}
