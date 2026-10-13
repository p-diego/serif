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
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error { NSLog("Serif: notification authorization failed: \(error)") }
        }
    }

    private func handle(bot id: UUID, record: ChatEventRecord) {
        guard let center, let bot = client.state.bots[id]?.bot else { return }
        guard record.seq > (lastSeq[id] ?? -1) else { return }
        lastSeq[id] = record.seq
        let windowKey = NSApp.isActive && NSApp.keyWindow != nil
        guard let kind = shouldNotify(event: record.event, bot: bot, viewingBot: client.selectedBot, windowKey: windowKey) else { return }
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
            content.body = reason
        default:    // rate limited
            content.title = String(localized: "\(bot.name) has reached its limit")
        }
        // Same identifier = replaced, so a repeated event never stacks.
        center.add(UNNotificationRequest(identifier: "\(id)-\(record.seq)", content: content, trigger: nil))
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
