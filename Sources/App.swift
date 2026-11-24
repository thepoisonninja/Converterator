// Converterator — App entry point, app delegate (Dock, Open With, Finder service) and menu commands.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // "Convert with Converterator" in Finder's right-click menu (declared as NSServices in Info.plist).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // Fetch newer Redump DATs in the background (at most once a day; can be turned off in Settings).
        MainActor.assumeIsolated {
            RedumpDB.shared.updateFromWeb()
            WatchFolder.shared.restart()
        }
    }

    /// The Finder service: adds the selected files and folders, and starts converting if that's turned on.
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        MainActor.assumeIsolated {
            let c = Converter.shared
            c.add(urls)
            NSApp.activate(ignoringOtherApps: true)
            if c.startFromFinder && !c.isRunning && c.toolsReady && c.hasQueued { c.start() }
        }
    }

    /// Files dropped on the Dock icon or opened with "Open With → Converterator".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Converter.shared.add(urls) }
    }
}

@main
struct ConverteratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Converterator", id: "main") { ContentView() }
            .defaultSize(width: 640, height: 520)
            .commands { AppCommands() }
        Window("Clean Up Originals", id: "cleanup") { CleanupView() }
            .defaultSize(width: 640, height: 520)
        Window("Library Report", id: "library") { LibraryView() }
            .defaultSize(width: 720, height: 640)
        Window("Check Against Redump", id: "chdcheck") { CHDCheckView() }
            .defaultSize(width: 680, height: 540)
        Window("Check for Damaged Files", id: "damage") { DamageCheckView() }
            .defaultSize(width: 700, height: 540)
        Settings { SettingsView() }
    }
}

/// Menu bar items and their keyboard shortcuts.
struct AppCommands: Commands {
    @ObservedObject private var c = Converter.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateChecker.shared.check() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") { NotificationCenter.default.post(name: .addFiles, object: nil) }
                .keyboardShortcut("o")
                .disabled(c.isRunning)
            Divider()
            Button("Clean Up Originals…") { openWindow(id: "cleanup") }
            Button("Check Against Redump…") { openWindow(id: "chdcheck") }
            Button("Check for Damaged Files…") { openWindow(id: "damage") }
            Button("Library Report…") { openWindow(id: "library") }
        }
        CommandMenu("Convert") {
            Button(c.isPaused ? "Resume" : "Convert") { NotificationCenter.default.post(name: .startConverting, object: nil) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(c.isRunning || !c.toolsReady || !c.hasQueued)
            Button("Pause After This File") { c.pause() }
                .keyboardShortcut("p")
                .disabled(!c.isRunning)
            Button("Stop Converting…") { NotificationCenter.default.post(name: .stopConverting, object: nil) }
                .keyboardShortcut(".")
                .disabled(!c.isRunning && !c.isPaused)
            Divider()
            Button("Clear Finished") { c.clearFinished() }
                .keyboardShortcut("k")
                .disabled(c.isRunning || c.jobs.isEmpty)
            Button("Retry Failed") { c.retryFailed() }
                .keyboardShortcut("r")
                .disabled(c.isRunning || !c.jobs.contains { $0.state == .failed })
            Button("Clear All") { c.clearAll() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(c.isRunning || c.jobs.isEmpty)
        }
        CommandGroup(replacing: .help) {
            Button("Converterator Help") {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateChecker.repo)#readme")!)
            }
            Divider()
            Button("Copy Diagnostic Info") { Diagnostics.copy() }
            Button("Report a Bug…") { Diagnostics.reportBug() }
            Button("Suggest a Feature…") {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateChecker.repo)/issues/new?template=feature_request.yml")!)
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Show or Hide Log") { NotificationCenter.default.post(name: .toggleLog, object: nil) }
                .keyboardShortcut("l")
        }
    }
}
