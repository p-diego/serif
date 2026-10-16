import SwiftUI
import AppKit
import SerifCore

/// "Diagnostics" (spec §8 of 0.7): versions and agents, the data folder, every bot's state, the log's tail; "Copy" puts
/// the whole page as plain text on the pasteboard, "Open the data folder" shows it in the Finder. With the engine off
/// the page shows the app's version and says the engine cannot be reached.
struct DiagnosticsView: View {
    let client: EngineClient
    @State private var diagnostics: Diagnostics?
    @State private var unreachable = false

    /// The page with the engine off: the app's version and the folder it would use.
    private static var offline: Diagnostics {
        Diagnostics(appVersion: EngineClient.appVersion, engineVersion: "", dataFolder: SerifPaths.standard().root.path,
                    agents: [], bots: [], logTail: [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(localized: "Diagnostics")).font(.system(size: Theme.Size.title, weight: .semibold))
                Spacer()
                CardButton(title: String(localized: "Reload"), style: .ghost) { Task { await load() } }
                CardButton(title: String(localized: "Open the data folder"), style: .ghost) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: (diagnostics ?? Self.offline).dataFolder))
                }
                CardButton(title: String(localized: "Copy"), style: .primary, enabled: diagnostics != nil) {
                    guard let diagnostics else { return }
                    // Without the engine only what the app knows: no false "Bots - none" (spec §8).
                    let text = unreachable ? "Serif \(diagnostics.appVersion)\nData folder: \(diagnostics.dataFolder)\nEngine not reachable"
                        : diagnosticsText(diagnostics)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .padding(.horizontal, 20).frame(height: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderTertiary).frame(height: 1) }
            ScrollView {
                if let d = diagnostics { page(d).padding(20) }
                else { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(40) }
            }
        }
        .font(.system(size: Theme.Size.body))
        .foregroundStyle(Theme.text)
        .background(Theme.pane)
        .task { await load() }
    }

    private func load() async {
        diagnostics = nil
        if let d = try? await client.diagnostics() { diagnostics = d; unreachable = false }
        else { diagnostics = Self.offline; unreachable = true }
    }

    @ViewBuilder private func page(_ d: Diagnostics) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            section(String(localized: "Versions")) {
                row(String(localized: "App"), d.appVersion)
                row(String(localized: "Engine"), unreachable ? String(localized: "Engine not reachable") : d.engineVersion)
                row(String(localized: "Data folder"), d.dataFolder)
            }
            if !unreachable {
                section(String(localized: "Agents")) {
                    ForEach(d.agents, id: \.agent) { a in
                        row(agentName(a.agent), a.path == nil ? String(localized: "not installed")
                            : [a.path ?? "", a.version ?? "", a.signedIn.map { $0 ? String(localized: "signed in") : String(localized: "not signed in") } ?? ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                }
                section(String(localized: "Bots")) {
                    if d.bots.isEmpty { Text(String(localized: "No bots")).foregroundStyle(Theme.textSecondary) }
                    ForEach(Array(d.bots.enumerated()), id: \.offset) { _, b in bot(b) }
                }
                section(String(localized: "Log (last \(d.logTail.count) lines)")) {
                    Text(d.logTail.joined(separator: "\n")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func bot(_ b: BotDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(b.name) · \(b.project) · \(agentName(b.agent))").font(.system(size: Theme.Size.body, weight: .medium))
            Text(stateText(b.state) ?? String(localized: "Ready")).foregroundStyle(Theme.textSecondary)
            Text(String(localized: "mail waiting: \(b.mailWaiting) · open cards: \(b.openCards) · routines: \(routinesText(b.routines))"))
                .font(.system(size: Theme.Size.small)).foregroundStyle(Theme.textSecondary)
            if let c = b.lastCrash {
                Text(String(localized: "last crash: \(c.at.formatted(date: .abbreviated, time: .shortened)) — \(crashReasonText(c.reason))"))
                    .font(.system(size: Theme.Size.small)).foregroundStyle(Theme.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func routinesText(_ routines: [BotDiagnostics.RoutineNext]) -> String {
        routines.isEmpty ? String(localized: "Diagnostics.none")
            : routines.map { "\($0.name) (\($0.next.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "never")))" }
                .joined(separator: ", ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: Theme.Size.label, weight: .medium)).foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 6) { content() }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.fillSecondary))
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }
}
