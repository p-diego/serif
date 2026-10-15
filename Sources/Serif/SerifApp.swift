import SwiftUI
import ServiceManagement
import SerifCore

@main
struct SerifApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Serif", id: "main") {
            RootView(client: delegate.client, updater: delegate.updater)
                .frame(minWidth: 900, minHeight: 600)

        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 760)
        // Started as a login item: stay in the Dock without a window; a Dock click opens it.
        .defaultLaunchBehavior(AppDelegate.launchedAtLogin ? .suppressed : .presented)
        .commands { AppCommands(delegate: delegate) }
        // Diagnostics (spec §8 of 0.7): its own window, from the Serif menu or ⌥⌘D.
        Window(String(localized: "Diagnostics"), id: "diagnostics") {
            DiagnosticsView(client: delegate.client).frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 760, height: 640)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Menu commands; also where the scene's `openWindow` action is captured, so a notification can reopen a closed window.
struct AppCommands: Commands {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = { AppDelegate.openMainWindow = { openWindow(id: "main") } }()
        CommandGroup(after: .appInfo) {
            Button(String(localized: "Check for Updates…")) { Task { await delegate.updater.checkFromMenu() } }
                .disabled(delegate.updater.isUpdating)
            Button(String(localized: "Diagnostics…")) { openWindow(id: "diagnostics") }
                .keyboardShortcut("d", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "New bot…")) { delegate.client.showNewBot() }.keyboardShortcut("n")
            Button(String(localized: "New project…")) { delegate.client.showNewProject() }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .appTermination) {
            Button(String(localized: "Quit and stop the bots")) { delegate.quitAndStopBots() }.keyboardShortcut("q", modifiers: [.command, .option])
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned here and started once at launch, never from view lifecycle (the window can be reopened).
    let client = EngineClient()
    lazy var updater = Updater(client: client)
    private var notifier: Notifier?

    static var openMainWindow: (() -> Void)?

    /// True when macOS started us as a login item; read from the launch Apple event (also re-read in willFinishLaunching).
    nonisolated(unsafe) static var launchedAtLogin = readLoginFlag()
    nonisolated private static func readLoginFlag() -> Bool {
        let flag = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        NSLog("Serif: launchedAtLogin=\(flag)")
        return flag
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        if !Self.launchedAtLogin { Self.launchedAtLogin = Self.readLoginFlag() }
    }

    // Closing the window leaves the app (and the notifications) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    /// Plain Quit leaves the bots running; this stops them first (the engine answers once they are down), waiting 10 s at most.
    private var quitting = false
    func quitAndStopBots() {
        guard !quitting else { return }
        quitting = true
        // The send continuation cannot be cancelled, so the 10 s limit is its own timer.
        let terminate = { @MainActor in NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { MainActor.assumeIsolated(terminate) }
        Task { @MainActor in
            try? await client.shutdownEngine()
            terminate()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        notifier = Notifier(client: client)
        client.start()
        updater.startChecking()
        // Login launch: no window (a fallback if the scene opened one anyway).
        if Self.launchedAtLogin { DispatchQueue.main.async { NSApp.windows.filter(\.canBecomeMain).forEach { $0.close() } } }
        guard EngineClient.runsFromApplications else { return }    // the client registers the engine agent itself
        do { try SMAppService.mainApp.register() } catch { NSLog("Serif: registering app failed: \(error)") }
    }
    func applicationDidBecomeActive(_ notification: Notification) { client.refreshEngineApproval() }
}

/// Window shell: sidebar, chat, optional right panel.
struct RootView: View {
    @Bindable var client: EngineClient
    let updater: Updater
    @State private var engineOff = false
    @State private var showPanel = false
    @State private var showTerminal = false
    @State private var collapsed = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(client: client, updater: updater, collapsed: $collapsed)
            Divider()
            ChatView(client: client, showPanel: $showPanel, showTerminal: $showTerminal)
            if showPanel {
                Divider()
                RightPanel(client: client, close: { showPanel = false }, openTerminal: { showTerminal = true })
            }
        }
        .overlay { if engineOff && !client.roster.connected { EngineOffOverlay(client: client) } }
        // Disconnected for more than 2 s: offer to start the engine.
        .task(id: client.roster.connected) {
            engineOff = false
            guard !client.roster.connected else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { engineOff = true }
        }
        .sheet(item: $client.sheet) { sheet in
            switch sheet {
            case .newProject: NewProjectSheet(client: client)
            case .newBot(let projectId): BotEditorSheet(client: client, editing: nil, projectId: projectId)
            case .editBot(let id):
                if let bot = client.roster.bots[id]?.bot { BotEditorSheet(client: client, editing: bot, projectId: nil) }
            case .editProject(let id):
                if let project = client.roster.projects.first(where: { $0.id == id }) {
                    ProjectSettingsSheet(client: client, project: project)
                }
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.chrome)
        .ignoresSafeArea()
    }
}
