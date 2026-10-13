import SwiftUI
import AppKit
import SerifCore

/// First launch (spec §4): welcome, Claude Code, notifications, first project; the New bot sheet follows. Shown in place of
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
                Text("Claude Code").font(.system(size: Theme.Size.title, weight: .semibold))
                ClaudeCheckView(client: client, onContinue: { step = 2 })
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

/// Claude Code installed and signed in, as the engine sees it (spec §4 step 2). Retry checks again; the first launch adds
/// Continue (on once nothing keeps bots from starting: an unknown sign-in does not), a stopped bot's card also restarts it.
struct ClaudeCheckView: View {
    let client: EngineClient
    /// After Retry's check; the spinner stays until it returns.
    var onRetry: (() async -> Void)?
    var onContinue: (() -> Void)?
    @State private var status: ClaudeStatus?
    @State private var checking = true

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    static let guide = URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status {
                installedRows(status)
                if status.installed { signInRows(status) }
            } else if !checking {
                Text(String(localized: "The engine did not answer")).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                CardButton(title: String(localized: "Retry"), enabled: !checking) { Task { await check(then: onRetry) } }
                if let onContinue {
                    CardButton(title: String(localized: "Continue"), style: .primary,
                               enabled: !checking && status != nil && status?.problem == nil, action: onContinue)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .font(.system(size: Theme.Size.body))
        .task { await check(then: nil) }
    }

    /// The engine's check can take up to ~20 s (`claude auth status` has 10 s): the spinner shows it is not stuck.
    private func check(then: (() async -> Void)?) async {
        checking = true
        status = try? await client.claudeStatus()
        await then?()
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

    @ViewBuilder private func installedRows(_ s: ClaudeStatus) -> some View {
        if s.installed {
            row(true, s.version.map { String(localized: "Claude Code \($0)") } ?? String(localized: "Claude Code is installed"))
        } else {
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
        }
    }

    @ViewBuilder private func signInRows(_ s: ClaudeStatus) -> some View {
        switch s.loggedIn {
        case true?:
            row(true, s.email.map { String(localized: "Signed in as \($0)") } ?? String(localized: "Signed in"))
        case false?:
            row(false, String(localized: "You are not signed in"))
            let hint = String(localized: "Open Terminal, type `claude` and follow the instructions.")
            Text((try? AttributedString(markdown: hint)) ?? AttributedString(hint))
                .foregroundStyle(Theme.textSecondary).padding(.leading, 26)
        case nil:
            row(nil, String(localized: "Could not check the sign-in"))
        }
    }
}

/// In the chat of a bot stopped because Claude Code is missing or signed out (spec §4): the first launch's check; Retry
/// also restarts the bot.
struct ClaudeHelpCard: View {
    let client: EngineClient
    let botId: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "This bot cannot start")).font(.system(size: Theme.Size.body, weight: .medium))
            ClaudeCheckView(client: client, onRetry: {
                try? await client.restart(bot: botId)
                // Fixed: the bot starts and this card goes away. Still broken: the engine checks again before it stops the
                // bot with the same reason (no visible change), so the spinner stays a little while.
                try? await Task.sleep(for: .seconds(3))
            })
        }
        .padding(12).frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.botBubble))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A crash reason as the user reads it: the two Claude Code problems are translated, any other reason is shown as is.
func crashReasonText(_ reason: String) -> String {
    switch ClaudeProblem(rawValue: reason) {
    case .notInstalled?: String(localized: "Claude Code is not installed")
    case .notSignedIn?: String(localized: "Claude Code is not signed in")
    case nil: reason
    }
}
