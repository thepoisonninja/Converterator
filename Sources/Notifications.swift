// Converterator — The batch-finished notification, and small extensions.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

// MARK: - Notifications

/// Posts "Batch finished" to Notification Center when a batch ends while you're in another app.
enum Notifier {
    /// Asks once; macOS remembers the answer, and it can be changed in System Settings → Notifications.
    /// Notification Center only works for a real .app bundle.
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor
    static func batchFinished(counts: String, saved: String?, failed: Bool) {
        guard available, !NSApp.isActive else { return }   // you're looking at the window already
        let content = UNMutableNotificationContent()
        content.title = failed ? "Batch finished with errors" : "Batch finished"
        content.body = ([counts] + (saved.map { [$0] } ?? [])).joined(separator: " · ")
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "batch-finished", content: content, trigger: nil))
    }
}

extension Notifier {
    /// A notification for something long that finished while you're in another app.
    @MainActor
    static func post(id: String, title: String, body: String) {
        guard available, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

extension Optional {
    /// Keeps the value only if it passes `test`.
    func filter(_ test: (Wrapped) -> Bool) -> Wrapped? { flatMap { test($0) ? $0 : nil } }
}
