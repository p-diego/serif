import SwiftUI
import SerifCore

/// A mail message in the chat (spec §9): received as a bubble on the bot's side saying who sent it and what it is, an
/// engine notice as a system line, sent as a line; the lines open to the whole text.
struct MailRow: View {
    let note: MailNote
    let maxWidth: CGFloat
    @State private var open = false

    var body: some View {
        switch (note.direction, note.kind) {
        case (.received, .system):
            line(noticeText(note), alignment: .center)
        case (.received, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(header).font(.system(size: Theme.Size.small, weight: .medium)).foregroundStyle(Theme.textSecondary)
                MarkdownText(text: note.text).textSelection(.enabled)
            }
            .padding(.vertical, 12).padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous).fill(Theme.botBubble))
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        case (.sent, _):
            line(sent, alignment: .leading)
        }
    }

    private var number: Int { note.taskNumber ?? 0 }

    private var header: String {
        switch note.kind {
        case .task: String(localized: "From \(note.from) · task #\(number)")
        case .reply: String(localized: "From \(note.from) · reply #\(number)")
        case .note, .system: String(localized: "From \(note.from) · note")
        }
    }

    private var sent: String {
        let start = String(note.text.split(separator: "\n").first?.prefix(80) ?? "")
        return switch note.kind {
        case .task: String(localized: "To \(note.to) · task #\(number): \(start)")
        case .reply: String(localized: "To \(note.to) · reply #\(number): \(start)")
        case .note, .system: String(localized: "To \(note.to) · note: \(start)")
        }
    }

    /// One line; a click shows the whole text under it.
    private func line(_ text: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(text).font(.system(size: Theme.Size.body)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            if open {
                Text(note.text).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.botBubble))
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
    }
}

/// What an engine notice says, in the app's language (spec §9); its English text is the bot's.
func noticeText(_ note: MailNote) -> String {
    let n = note.taskNumber ?? 0
    switch note.notice {
    case .done?: return String(localized: "Task #\(n) is done")
    case .cancelledByRequester?: return String(localized: "Task #\(n) was cancelled by \(note.from)")
    case .cancelledByUser?: return String(localized: "You cancelled task #\(n)")
    case .cancelledArchived?: return String(localized: "Task #\(n) was cancelled: \(note.from) was archived")
    case .expired?: return String(localized: "Task #\(n) expired without a reply")
    case nil: return note.text
    }
}

/// A task's card (spec §9): number, who asked whom, the text, the deadline and its state, with the result once done;
/// Cancel while it is open. The engine records it again at every change, and the chat redraws it in place.
struct TaskCardView: View {
    let card: TaskCard
    let projectId: UUID
    let client: EngineClient
    @State private var busy = false
    @State private var error: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Task #\(card.number)")).font(.system(size: Theme.Size.body, weight: .medium))
                Spacer(minLength: 8)
                StatusPill(kind: pill.kind, text: pill.text)
            }
            let due = card.deadline.formatted(date: .abbreviated, time: .shortened)
            Text(String(localized: "\(card.from) → \(card.to) · due \(due)"))
                .font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
            Text(card.text).font(.system(size: Theme.Size.body)).lineLimit(expanded ? nil : 3).textSelection(.enabled)
            if let result = card.result {
                Text(result).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(expanded ? nil : 3).textSelection(.enabled)
            }
            if card.status == .open {
                HStack {
                    if let error { Text(error).font(.system(size: Theme.Size.small)).foregroundStyle(Theme.red) }
                    Spacer(minLength: 0)
                    CardButton(title: String(localized: "Cancel"), style: .ghost, enabled: !busy, action: cancel)
                }
            }
        }
        .padding(12).frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.botBubble))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pill: (kind: StatusPill.Kind, text: String) {
        switch card.status {
        case .open: (.waiting, String(localized: "Task.open"))
        case .done: (.done, String(localized: "Task.done"))
        case .cancelled: (.neutral, String(localized: "Cancelled"))
        case .expired: (.failed, String(localized: "Task.expired"))
        }
    }

    /// The user's Cancel (spec §5): both bots are told; the card changes when the engine records it.
    private func cancel() {
        busy = true; error = nil
        Task {
            do { try await client.cancelTask(project: projectId, number: card.number) }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
