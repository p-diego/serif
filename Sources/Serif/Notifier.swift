import AppKit
import SwiftUI
import UserNotifications
import SerifCore

/// Out-of-window signals: Dock badge, notifications, the runtime app icon.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let client: EngineClient
    /// Notifications only work from a bundle; an unbundled `swift run` skips them.
    private let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier != nil ? .current() : nil

    private var badge: Int?
    /// Last seq notified per bot: replays after a reconnect never notify twice.
    private var lastSeq: [UUID: Int] = [:]
    /// Who started each bot's current turn: a turn the mail started ends without a notification (spec §6).
    private var turnOrigin: [UUID: MessageOrigin] = [:]
    /// Whether the routine of each bot's current run notifies (spec §4 of 0.6): "Tell me when it finishes".
    private var routineNotifies: [UUID: Bool] = [:]

    init(client: EngineClient) {
        self.client = client
        super.init()
        client.onWaitingCount = { [weak self] count in
            guard self?.badge != count else { return }
            self?.badge = count
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        client.onChatEvent = { [weak self] bot, record in self?.handle(bot: bot, record: record) }
        guard let center else { return }
        center.delegate = self
    }

    /// Asks macOS for notifications while the choice is still open: from the first launch's "Enable notifications", or the
    /// first time a bot waits for you after "Not now" (spec §4). Once answered it does nothing.
    static func requestAuthorizationIfNeeded() async {
        guard Bundle.main.bundleIdentifier != nil else { return }      // unbundled `swift run`: no notifications
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { NSLog("Serif: notification authorization failed: \(error)") }
    }

    private func handle(bot id: UUID, record: ChatEventRecord) {
        guard let center, let bot = client.state.bots[id]?.bot else { return }
        guard record.seq > (lastSeq[id] ?? -1) else { return }
        lastSeq[id] = record.seq
        if case let .userMessage(_, _, origin) = record.event { turnOrigin[id] = origin }
        if case let .routineRun(run) = record.event, run.outcome == nil { routineNotifies[id] = run.notifies }
        // "Not now" at first launch: macOS asks the first time a bot waits for you; this notification waits for the answer.
        var asking: Task<Void, Never>?
        if case .requestOpened = record.event { asking = Task { await Self.requestAuthorizationIfNeeded() } }
        let windowKey = NSApp.isActive && NSApp.keyWindow != nil
        guard let kind = shouldNotify(event: record.event, bot: bot, viewingBot: client.selectedBot, windowKey: windowKey,
                                      turnOrigin: turnOrigin[id], routineNotifies: routineNotifies[id] ?? true) else { return }
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.userInfo = ["bot": id.uuidString]
        switch (kind, record.event) {
        case (.waiting, .requestOpened(let request)):
            content.title = String(localized: "\(bot.name) is waiting for you")
            content.body = requestSummary(request).text
        case (.finished, .turnEnded(_, let last)):
            content.title = String(localized: "\(bot.name) has finished")
            content.body = String(plainText(markdown: last ?? "").prefix(120))
        case (.failed, .turnFailed(let reason)), (.failed, .system(.crashed(let reason))):
            content.title = String(localized: "\(bot.name) has stopped")
            content.body = crashReasonText(reason)
        default:    // rate limited
            content.title = String(localized: "\(bot.name) has reached its limit")
        }
        // Same identifier = replaced, so a repeated event never stacks.
        let request = UNNotificationRequest(identifier: "\(id)-\(record.seq)", content: content, trigger: nil)
        Task {
            await asking?.value
            try? await center.add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let string = response.notification.request.content.userInfo["bot"] as? String, let id = UUID(uuidString: string) else { return }
        await MainActor.run {
            client.selectedBot = id
            NSApp.activate()
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) { window.makeKeyAndOrderFront(nil) }
            else if let open = AppDelegate.openMainWindow { open() }
            else { NSWorkspace.shared.open(Bundle.main.bundleURL) }    // same path as a Dock click
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]    // shouldNotify already decided this one is worth showing
    }
}
