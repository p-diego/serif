import SwiftUI
import AppKit
import ServiceManagement
import SerifCore

struct SidebarView: View {
    let client: EngineClient
    let updater: Updater
    @Binding var collapsed: Bool
    @State private var search = ""

    private var initials: String {
        let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        return name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        let state = client.roster
        VStack(spacing: 0) {
            topBar
            if collapsed { collapsedList(state) } else { fullList(state) }
            Spacer(minLength: 0)
            if client.engineNeedsApproval && !collapsed { approvalHint }
            if !collapsed { updateRow }
            userArea
        }
        .frame(width: collapsed ? 76 : Theme.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    // Same height as the title bar (52), the "+" aligned with the traffic lights.
    private var topBar: some View {
        HStack(spacing: 4) {
            Spacer()
            if !collapsed { toggleButton; plusMenu }
        }
        .padding(.trailing, 14).frame(height: 52)
    }

    private var toggleButton: some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() } } label: {
            Image(systemName: "sidebar.left").font(.system(size: 15)).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
        .keyboardShortcut("s", modifiers: [.command, .option])
        .help(String(localized: "Collapse the list"))
    }

    private var plusMenu: some View {
        Menu {
            Button(String(localized: "New bot…")) { client.showNewBot() }
            Button(String(localized: "New project…")) { client.showNewProject() }
        } label: {
            Image(systemName: "plus").font(.system(size: 17, weight: .light)).frame(width: 28, height: 28)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Theme.textSecondary)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.textTertiary)
            TextField(String(localized: "Search"), text: $search).textFieldStyle(.plain).font(.system(size: Theme.Size.body))
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.fillSecondary))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row).stroke(Theme.border, lineWidth: 0.5))
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func fullList(_ state: ClientState) -> some View {
        VStack(spacing: 0) {
            searchField
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if search.isEmpty, !state.pinned.isEmpty {
                        PinnedRow(pinned: state.pinned, selected: client.selectedBot, client: client).padding(.bottom, 6)
                    }
                    ForEach(state.sections(search: search), id: \.project.id) { section in
                        Text(section.project.name.uppercased())
                            .font(.system(size: Theme.Size.caption, weight: .medium)).tracking(0.4)
                            .foregroundStyle(Theme.textTertiary).lineLimit(1)
                            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 4)
                        ForEach(section.bots, id: \.bot.id) { s in
                            BotRow(summary: s, selected: client.selectedBot == s.bot.id,
                                   request: state.requests.values.filter { $0.botId == s.bot.id }.min { $0.openedAt < $1.openedAt }, client: client).equatable()
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // 76 pt column of mascots only.
    private func collapsedList(_ state: ClientState) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) { plusMenu; toggleButton }.padding(.bottom, 6)
            ScrollView {
            VStack(spacing: 6) {
                ForEach(state.sections(search: ""), id: \.project.id) { section in
                    ForEach(section.bots, id: \.bot.id) { s in
                        BotAvatar(summary: s, size: 44)
                            .frame(width: 60, height: 56)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(client.selectedBot == s.bot.id ? Theme.active : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { client.selectedBot = s.bot.id }
                            .contextMenu { BotMenu(summary: s, client: client) }
                            .help(s.bot.name)
                    }
                }
            }
            }
        }
    }

    /// Non-blocking: the app runs the engine itself until the user allows the login item.
    private var approvalHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "To keep the bots running when the app is closed, allow Serif in System Settings › General › Login Items"))
                .font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "Open Settings")) { SMAppService.openSystemSettingsLoginItems() }
                .buttonStyle(.plain).font(.system(size: Theme.Size.small, weight: .medium)).foregroundStyle(Theme.text)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.fillSecondary))
        .padding(.horizontal, 16).padding(.top, 8)
    }

    /// Only when there is something to say: a newer version, its download, or an install that failed.
    @ViewBuilder private var updateRow: some View {
        switch updater.state {
        case .available(let release):
            updateButton(String(localized: "Update to \(release.version)"), icon: "arrow.down.circle") { Task { await updater.update() } }
        case .downloading:
            updateButton(String(localized: "Updating…"), icon: nil, action: nil)
        case .failed(let reason):
            updateButton(String(localized: "Update failed · download it"), icon: "exclamationmark.triangle") {
                NSWorkspace.shared.open(latestReleasePage)
            }
            .help(reason)
        case .idle, .upToDate:
            EmptyView()
        }
    }

    /// A row the size of the search field; no icon = a spinner, no action = disabled.
    private func updateButton(_ title: String, icon: String?, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) } else { ProgressView().controlSize(.small) }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: Theme.Size.body)).padding(.horizontal, 10).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.fillSecondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(action == nil)
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var userArea: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(initials).font(.system(size: Theme.Size.label, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, height: 36).background(Circle().fill(Theme.active))
                if !collapsed { Text(NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()).font(.system(size: Theme.Size.body)).lineLimit(1) }
                if !collapsed { Spacer() }
            }
        }
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
        .padding(.horizontal, collapsed ? 0 : 18).padding(.bottom, 16).padding(.top, 8)
    }
}
