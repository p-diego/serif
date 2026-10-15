import SwiftUI
import SerifCore

/// "Waiting for you" (spec §7 of 0.6): every open card of every live bot, grouped by bot, answered here with the same
/// cards as the chat. A card answered goes; with none left the view goes back to the bot you were looking at.
struct WaitingView: View {
    let client: EngineClient

    var body: some View {
        let requests = client.roster.waitingForYou
        let groups = Dictionary(grouping: requests, by: \.botId)
            .compactMap { id, cards in client.roster.bots[id].map { ($0, cards) } }
            .sorted { $0.0.bot.name.localizedStandardCompare($1.0.bot.name) == .orderedAscending }
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Waiting.title")).font(.system(size: 16, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 20).frame(height: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderTertiary).frame(height: 1) }
            if requests.isEmpty {
                Text(String(localized: "Nothing is waiting for you"))
                    .font(.system(size: Theme.Size.body)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(groups, id: \.0.bot.id) { summary, cards in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 10) {
                                    BotAvatar(summary: summary, size: 24)
                                    Text(summary.bot.name).font(.system(size: Theme.Size.body, weight: .medium))
                                    Spacer()
                                    CardButton(title: String(localized: "Open the chat"), style: .ghost) {
                                        client.selectedBot = summary.bot.id
                                    }
                                }
                                ForEach(cards) { RequestCard(request: $0, resolution: nil, given: nil, client: client) }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onChange(of: requests.isEmpty) { _, empty in if empty { client.showWaiting = false } }
    }
}
