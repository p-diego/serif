import SwiftUI
import SerifCore

/// Pinned bots: big mascots with the name underneath.
struct PinnedRow: View {
    let pinned: [BotSummary]
    let selected: UUID?
    let client: EngineClient

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pinned, id: \.bot.id) { s in
                    VStack(spacing: 4) {
                        BotAvatar(summary: s, size: 52)
                        Text(s.bot.name).font(.system(size: Theme.Size.label)).lineLimit(1).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(width: 68).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(selected == s.bot.id ? Theme.active : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { client.selectedBot = s.bot.id }
                    .contextMenu { BotMenu(summary: s, client: client) }
                }
            }
            .padding(.horizontal, 10)
        }
    }
}
