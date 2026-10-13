import SwiftUI
import AppKit
import SerifCore

/// First launch (spec §4, §7): welcome, agents, notifications, first project; the New bot sheet follows. Shown in place of
/// the empty state while there is no project and no bot was ever created from this app (`doneKey`).
struct OnboardingView: View {
    static let doneKey = "onboardingDone"
    let client: EngineClient
    @State private var step = 0
    @State private var name = ""
    @State private var folder: String?
    @State private var readInstructions = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            ScatteredMascots()
            if step == 0 { welcome } else { card }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
        VStack(spacing: 8) {
            Text("Serif").font(.system(size: 28, weight: .semibold))
            Text(String(localized: "Your bots, always at work")).font(.system(size: Theme.Size.body)).foregroundStyle(Theme.textSecondary)
            Button { step = 1 } label: {
                Text(String(localized: "Get started")).font(.system(size: Theme.Size.body, weight: .medium))
                    .foregroundStyle(Theme.userBubbleText).padding(.horizontal, 20).frame(height: 38)
                    .background(Capsule().fill(Theme.userBubble))
            }.buttonStyle(.plain).padding(.top, 10)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case 1:
                Text(String(localized: "Agents")).font(.system(size: Theme.Size.title, weight: .semibold))
                AgentCheckView(client: client, agents: [.claude, .codex], onContinue: { step = 2 })
            case 2:
                Text(String(localized: "Notifications")).font(.system(size: Theme.Size.title, weight: .semibold))
                Text(String(localized: "Serif tells you when a bot is waiting for you or has finished, even when the app is closed."))
                    .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer()
                    CardButton(title: String(localized: "Not now")) { step = 3 }
                    // Only here does macOS ask; "Not now" leaves it to the first bot that waits for you (Notifier).
                    CardButton(title: String(localized: "Enable notifications"), style: .primary) {
                        Task { await Notifier.requestAuthorizationIfNeeded(); step = 3 }
                    }.keyboardShortcut(.defaultAction)
                }
            default:
                Text(String(localized: "Your first project")).font(.system(size: Theme.Size.title, weight: .semibold))
                ProjectFields(name: $name, folder: $folder, readInstructions: $readInstructions)
                HStack(spacing: 10) {
                    if let error { Text(error).font(.system(size: Theme.Size.label)).foregroundStyle(Theme.red).lineLimit(2) }
                    Spacer()
                    CardButton(title: String(localized: "Create"), style: .primary, enabled: canCreateProject(name: name) && !busy,
                               action: create).keyboardShortcut(.defaultAction)
                }
            }
        }
        .font(.system(size: Theme.Size.body))
        .padding(24).frame(width: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
    }

    /// As the New project sheet: the New bot sheet opens on the new project; creating the bot ends the first launch.
    private func create() {
        busy = true; error = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let project = try await client.createProject(name: trimmed, linkedFolder: folder, readLinkedInstructions: readInstructions)
                client.sheet = .newBot(projectId: project.id)
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}

/// The agents installed and signed in, as the engine sees them (spec §4 step 2 of 0.3, §7). Retry checks again; the first
/// launch adds Continue, on once nothing keeps Claude Code's bots from starting (an unknown sign-in does not; Codex is
/// optional). A check that finds an agent fine also starts the bots it had stopped (the engine does it).
struct AgentCheckView: View {
    let client: EngineClient
    let agents: [Agent]
    var onContinue: (() -> Void)?
    @State private var statuses: [Agent: AgentStatus] = [:]
    @State private var checking = true

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    static let guide = URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")!
    static let codexGuide = URL(string: "https://developers.openai.com/codex/cli")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(agents, id: \.self) { agent in
                if agents.count > 1 {
                    Text(agent == .claude ? "Claude Code" : String(localized: "Codex (optional)"))
                        .font(.system(size: Theme.Size.body, weight: .medium)).padding(.top, agent == agents.first ? 0 : 6)
                }
                if let status = statuses[agent] {
                    installedRows(status)
                    if status.installed { signInRows(status) }
                } else if !checking {
                    Text(String(localized: "The engine did not answer")).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                CardButton(title: String(localized: "Retry"), enabled: !checking) { Task { await check() } }
                if let onContinue {
                    CardButton(title: String(localized: "Continue"), style: .primary,
                               enabled: !checking && statuses[.claude] != nil && statuses[.claude]?.problem == nil, action: onContinue)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .font(.system(size: Theme.Size.body))
        .task { await check() }
    }

    /// The engine's check can take up to ~20 s per agent (a sign-in check has 10 s): the spinner shows it is not stuck.
    private func check() async {
        checking = true
        for agent in agents { statuses[agent] = try? await client.agentStatus(agent) }
        checking = false
    }

    private func row(_ ok: Bool?, _ title: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "xmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(ok == true ? Theme.green : ok == false ? Theme.red : Theme.textTertiary)
        }
    }

    private func hint(_ markdown: String) -> some View {
        Text((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)).foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder private func installedRows(_ s: AgentStatus) -> some View {
        switch (s.agent, s.installed) {
        case (.claude, true):
            row(true, s.version.map { String(localized: "Claude Code \($0)") } ?? String(localized: "Claude Code is installed"))
        case (.codex, true):
            row(true, s.version.map { String(localized: "Codex \($0)") } ?? String(localized: "Codex is installed"))
        case (.claude, false):
            row(false, String(localized: "Claude Code is not installed"))
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Install it in Terminal with:")).foregroundStyle(Theme.textSecondary)
                HStack {
                    Text(Self.installCommand).font(.system(size: Theme.Size.small, design: .monospaced)).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button(String(localized: "Copy")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Self.installCommand, forType: .string)
                    }
                    .buttonStyle(.plain).font(.system(size: Theme.Size.label)).foregroundStyle(Theme.textSecondary)
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.codeBackground))
                Link(String(localized: "Installation guide"), destination: Self.guide)
            }
            .padding(.leading, 26)
        case (.codex, false):
            row(false, String(localized: "Codex is not installed"))
            VStack(alignment: .leading, spacing: 6) {
                hint(String(localized: "Install the ChatGPT app, or the Codex CLI."))
                Link(String(localized: "Installation guide"), destination: Self.codexGuide)
            }
            .padding(.leading, 26)
        }
    }

    @ViewBuilder private func signInRows(_ s: AgentStatus) -> some View {
        switch s.loggedIn {
        case true?:
            row(true, s.email.map { String(localized: "Signed in as \($0)") } ?? String(localized: "Signed in"))
        case false?:
            row(false, String(localized: "You are not signed in"))
            hint(s.agent == .claude ? String(localized: "Open Terminal, type `claude` and follow the instructions.")
                                    : String(localized: "Open Terminal, type `codex login` and follow the instructions."))
                .padding(.leading, 26)
        case nil:
            row(nil, String(localized: "Could not check the sign-in"))
        }
    }
}

/// In the chat of a bot stopped because its agent is missing or signed out (spec §4 of 0.3, §7): the first launch's check
/// for that agent. Once a check finds it fine the engine starts the bot and this card goes away.
struct AgentHelpCard: View {
    let client: EngineClient
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "This bot cannot start")).font(.system(size: Theme.Size.body, weight: .medium))
            AgentCheckView(client: client, agents: [agent])
        }
        .padding(12).frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.botBubble))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A crash reason as the user reads it: the agents' problems and Codex's own stops are translated, any other reason is
/// shown as is.
func crashReasonText(_ reason: String) -> String {
    switch reason {
    case AgentProblem.claudeNotInstalled.rawValue: String(localized: "Claude Code is not installed")
    case AgentProblem.claudeNotSignedIn.rawValue: String(localized: "Claude Code is not signed in")
    case AgentProblem.codexNotInstalled.rawValue: String(localized: "Codex is not installed")
    case AgentProblem.codexNotSignedIn.rawValue: String(localized: "Codex is not signed in")
    case CodexText.isolation: String(localized: "Isolation not guaranteed")
    case CodexText.notStarted: String(localized: "Codex did not start in time")
    default: reason
    }
}
