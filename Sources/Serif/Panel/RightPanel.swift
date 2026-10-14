import SwiftUI
import SerifCore

/// Right panel (demo-4): gear and close on top, the bot's screen, then its details.
struct RightPanel: View {
    let client: EngineClient
    let close: () -> Void
    let openTerminal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer()
                if let id = client.chat.summary?.bot.id {
                    iconButton("gearshape", help: String(localized: "Bot settings")) { client.showBotSettings(id) }
                }
                iconButton("xmark", help: String(localized: "Close")) { close() }
            }
            .padding(.horizontal, 12).frame(height: 52)
            if let summary = client.chat.summary {
                ScrollView { PanelContent(client: client, summary: summary, openTerminal: openTerminal).id(summary.bot.id).padding(16) }
            } else {
                Spacer()
            }
        }
        .frame(width: Theme.panelWidth)
        .background(Theme.sidebar)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 15)).frame(width: 28, height: 28) }
            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(help)
    }
}

private struct PanelContent: View {
    let client: EngineClient
    let summary: BotSummary
    let openTerminal: () -> Void

    private var bot: Bot { summary.bot }
    private var linked: String? { client.roster.projects.first { $0.id == bot.projectId }?.linkedFolder }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            Text(String(localized: "Screen of \(bot.name)"))
                .font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity).padding(.top, 10)
            Text("Information").font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
                .padding(.top, 28).padding(.bottom, 8)
            infoRow(String(localized: "Agent"), bot.agent == .claude ? "Claude Code" : "Codex")
            infoRow(String(localized: "Model"), bot.model ?? String(localized: "Default"))
            infoRow(String(localized: "Freedom"), freedomText)
            folderRow(String(localized: "Working folder"), URL(fileURLWithPath: workspace))
            folderRow(String(localized: "Shared folder"), SerifPaths.standard().shared(bot.projectId))
            if let linked { folderRow(String(localized: "Linked folder"), URL(fileURLWithPath: linked)) }
            Toggle(String(localized: "Notifications"), isOn: Binding(get: { bot.notifications }, set: { value in
                var updated = bot; updated.notifications = value
                Task { try? await client.updateBot(updated) }
            }))
            .toggleStyle(.switch).font(.system(size: Theme.Size.body)).padding(.top, 10)
        }
    }

    private var workspace: String { SerifPaths.standard().bot(bot.id).workspace.path }

    private var freedomText: String {
        switch bot.freedom {
        case .ask: String(localized: "Asks permission")
        case .edits: String(localized: "Edits files on its own")
        case .auto: String(localized: "Automatic")
        }
    }

    @ViewBuilder private var preview: some View {
        if bot.agent == .codex {
            // A Codex bot's terminal is a real Codex on its thread: started for the Terminal view only, never for a preview.
            Button(String(localized: "Open the terminal"), action: openTerminal)
                .frame(maxWidth: .infinity, minHeight: 160)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.pane))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
        } else {
            claudePreview
        }
    }

    private var claudePreview: some View {
        PreviewTerminal(session: client.terminal(for: bot.id))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { StoppedOverlay(state: summary.state, radius: 12) }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
            .overlay { Color.clear.contentShape(Rectangle()).onTapGesture(perform: openTerminal) }    // also shields the view from the mouse
            .help(String(localized: "Open the terminal"))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).lineLimit(1)
        }
        .font(.system(size: Theme.Size.body)).padding(.vertical, 5)
    }

    private func folderRow(_ title: String, _ url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(Theme.textSecondary)
                Text(title)
                Spacer()
                Text(url.lastPathComponent).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: Theme.Size.body)).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(url.path)
    }
}
