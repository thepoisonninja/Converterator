// Converterator — File → Clean Up Originals…
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

// MARK: - Clean up originals

/// Finds source files that already have their CHDs (for folders converted with the Trash option off)
/// and moves the ones you pick to the Trash, optionally after verifying each CHD.
@MainActor
final class Cleanup: ObservableObject {
    static let shared = Cleanup()

    struct Item: Identifiable, Sendable {
        let id = UUID()
        let source: URL          // what was converted: .cue/.gdi/.iso/.pbp/.zip/.7z
        let files: [URL]         // what goes to the Trash: the source plus its track files
        let bytes: Double
        let chds: [URL]          // the CHDs that cover it
        var include = true
        var problem: String?     // set if its CHD failed verification
    }

    enum Phase: Equatable { case idle, scanning, review, working, done }

    @Published var phase: Phase = .idle
    @Published var folder: URL?
    @Published var items: [Item] = []
    @Published var verifyFirst = true
    @Published var status = ""
    @Published var progress = 0.0
    @Published var summary = ""
    /// Files left out because they share a CHD name with another file, so it's unclear which one the CHD came from.
    @Published var ambiguous = 0
    private var cancelled = false

    var selected: [Item] { items.filter(\.include) }
    var selectedBytes: Double { selected.reduce(0) { $0 + $1.bytes } }

    func scan(_ folder: URL) {
        self.folder = folder
        phase = .scanning
        items = []
        status = "Looking for converted files…"
        let outDir = Converter.shared.outputDir
        let sevenZip = Converter.shared.sevenZip
        Task.detached {
            let found = Cleanup.findConverted(in: folder, outputDir: outDir, sevenZip: sevenZip, log: ConversionLog.load())
            let (clear, skipped) = Cleanup.unambiguous(found)
            await MainActor.run {
                self.ambiguous = skipped
                self.items = clear
                self.phase = .review
            }
        }
    }

    func cancel() { cancelled = true }

    func reset() {
        phase = .idle; folder = nil; items = []; summary = ""; ambiguous = 0; progress = 0
    }

    /// Verifies (optionally) and trashes every included item. Items whose CHD fails stay put.
    func run() {
        let chosen = selected
        guard !chosen.isEmpty else { return }
        phase = .working
        cancelled = false
        progress = 0
        Task {
            var trashed = 0, trashedBytes = 0.0, kept = 0
            let fm = FileManager.default
            let chdman = Converter.shared.chdman
            for (n, item) in chosen.enumerated() {
                if cancelled { break }
                status = "\(verifyFirst ? "Verifying and moving" : "Moving") \(n + 1) of \(chosen.count): \(item.source.lastPathComponent)"
                progress = Double(n) / Double(chosen.count)
                var ok = item.chds.allSatisfy { totalSize([$0]) > 0 }
                if ok && verifyFirst, let chdman {
                    for chd in item.chds {
                        let base = progress, share = 1 / Double(chosen.count) / Double(item.chds.count)
                        let good = await Cleanup.verify(chd, chdman: chdman) { p in
                            Task { @MainActor in self.progress = base + share * p }
                        }
                        if !good { ok = false; break }
                        if cancelled { break }
                    }
                }
                if cancelled { break }
                guard ok else {
                    kept += 1
                    if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].problem = "CHD failed verification — kept" }
                    continue
                }
                var failures: [String] = []
                for f in item.files where fm.fileExists(atPath: f.path) {
                    do { try fm.trashItem(at: f, resultingItemURL: nil) } catch { failures.append(f.lastPathComponent) }
                }
                if !failures.isEmpty {
                    kept += 1
                    if let i = items.firstIndex(where: { $0.id == item.id }) {
                        items[i].problem = "Couldn't move \(failures.joined(separator: ", ")) to the Trash"
                    }
                    continue
                }
                trashed += 1
                trashedBytes += item.bytes
                items.removeAll { $0.id == item.id }
            }
            progress = 1
            var parts = [trashed == 0 ? "Nothing was moved to the Trash."
                         : "Moved \(trashed) item\(trashed == 1 ? "" : "s") (\(formatBytes(trashedBytes))) to the Trash."]
            if kept > 0 { parts.append("Kept \(kept): see the red notes below.") }
            if cancelled { parts.append("Stopped before the rest.") }
            parts.append("You can put anything back from the Trash.")
            summary = parts.joined(separator: " ")
            phase = .done
        }
    }

    // MARK: Matching

    /// Two different originals pointing at the same CHD (e.g. many "Disc 1.cue" files and one shared
    /// Save to: folder) can't both be its source. Leaves them all out rather than guess; returns how many.
    nonisolated static func unambiguous(_ found: [Item]) -> ([Item], Int) {
        var uses: [String: Int] = [:]
        for item in found { for chd in Set(item.chds.map(\.standardizedFileURL.path)) { uses[chd, default: 0] += 1 } }
        let clear = found.filter { $0.chds.allSatisfy { uses[$0.standardizedFileURL.path] == 1 } }
        return (clear, found.count - clear.count)
    }

    /// Every disc image (or archive of them) under `folder` whose CHDs all exist, next to it or in `outputDir`.
    nonisolated static func findConverted(in folder: URL, outputDir: URL?, sevenZip: URL?,
                                          log: [String: [String]] = [:]) -> [Item] {
        scanSources(in: folder, outputDir: outputDir, sevenZip: sevenZip, log: log).converted
    }

    /// Every disc image (or archive with one inside) under `folder`, split into those whose CHDs all exist
    /// and those that haven't been converted.
    nonisolated static func scanSources(in folder: URL, outputDir: URL?, sevenZip: URL?,
                                        log: [String: [String]] = [:]) -> (converted: [Item], unconverted: [URL]) {
        let fm = FileManager.default
        var result: [Item] = []
        var unconverted: [URL] = []
        let files = (fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .allObjects as? [URL] ?? [])
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        for f in files {
            let ext = f.pathExtension.lowercased()
            // Part 2, 3… of a multi-part archive go with part 1; an ECM track listed by a .cue goes with the .cue.
            if Converter.archiveExtensions.contains(ext) && Converter.isLaterPart(f) { continue }
            if ext == "ecm" && ECM.sheet(for: f) != nil { continue }
            let dirs = [f.deletingLastPathComponent()] + (outputDir.map { [$0] } ?? [])
            var chds: [URL]?
            var trash: [URL] = [f]
            // CHDs recorded when it was converted (they may be named differently, e.g. after Redump).
            let recorded = (log[f.standardizedFileURL.path] ?? []).map { URL(fileURLWithPath: $0) }
            if !recorded.isEmpty && recorded.allSatisfy({ totalSize([$0]) > 0 }) {
                chds = recorded
                trash = Converter.sourceFiles(for: f) + Converter.companionFiles(for: f)
            } else if ext == "ecm" {
                chds = covering(base: ECM.gameName(f), isPBP: false, in: dirs)
            } else if Converter.inputExtensions.contains(ext) {
                chds = covering(base: f.deletingPathExtension().lastPathComponent, isPBP: ext == "pbp", in: dirs)
                trash = Converter.sourceFiles(for: f) + Converter.companionFiles(for: f)
            } else if Converter.archiveExtensions.contains(ext) {
                let names = ext == "zip" ? Converter.zipEntryNames(f) : sevenZip.flatMap { sevenZipNames(f, tool: $0) }
                func extOf(_ n: String) -> String { (n as NSString).pathExtension.lowercased() }
                // The disc images inside; ECM-compressed tracks count only when there's no .cue/.gdi for them.
                let sheets = (names ?? []).filter { Converter.inputExtensions.contains(extOf($0)) }
                let games = sheets.isEmpty ? (names ?? []).filter { extOf($0) == "ecm" } : sheets
                if games.isEmpty { continue }   // not a disc archive (e.g. zipped cartridge games)
                trash = Converter.sourceFiles(for: f)   // (every part of a multi-part archive)
                do {
                    var all: [URL] = []
                    for g in games {
                        let name = (g as NSString).lastPathComponent
                        let base = extOf(name) == "ecm" ? ECM.gameName(URL(fileURLWithPath: name)) : (name as NSString).deletingPathExtension
                        guard let c = covering(base: base,
                                               isPBP: (name as NSString).pathExtension.lowercased() == "pbp", in: dirs)
                        else { all = []; break }
                        all += c
                    }
                    if !all.isEmpty { chds = all }
                }
            }
            if let chds, !chds.isEmpty {
                result.append(Item(source: f, files: trash, bytes: totalSize(trash), chds: chds))
            } else if Converter.inputExtensions.contains(ext) || Converter.archiveExtensions.contains(ext) || ext == "ecm" {
                unconverted.append(f)
            }
        }
        return (result, unconverted)
    }

    /// The CHDs for one game: `base.chd`, or for a multi-disc PBP the CHDs its `base.m3u` lists.
    /// Nil unless they all exist and aren't empty.
    nonisolated static func covering(base: String, isPBP: Bool, in folders: [URL]) -> [URL]? {
        // (Also in a folder per system inside each, when games are sorted that way.)
        let dirs = folders.flatMap { d in [d] + Systems.folderNames.map { d.appendingPathComponent($0, isDirectory: true) } }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        for dir in dirs {
            // (A GameCube/Wii disc's is an .rvz.)
            for ext in ["chd", "rvz"] {
                let out = dir.appendingPathComponent(base + "." + ext)
                if totalSize([out]) > 0 { return [out] }
            }
        }
        guard isPBP else { return nil }
        for dir in dirs {
            let m3u = dir.appendingPathComponent(base + ".m3u")
            guard let text = try? String(contentsOf: m3u, encoding: .utf8) else { continue }
            let listed = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { dir.appendingPathComponent($0) }
            if !listed.isEmpty, listed.allSatisfy({ $0.pathExtension.lowercased() == "chd" && totalSize([$0]) > 0 }) {
                return listed
            }
        }
        return nil
    }

    /// File names inside a .7z or .rar, from `7zz l`.
    nonisolated static func sevenZipNames(_ url: URL, tool: URL) -> [String]? {
        Converter.sevenZipEntries(url, tool: tool)?.map(\.name)
    }

    /// Runs `chdman verify`, reporting progress; stops it if it makes no progress for the stall timeout.
    nonisolated static func verify(_ chd: URL, chdman: URL, progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        final class State: @unchecked Sendable {
            let lock = NSLock(); var last = Date(); var pct = -1.0
            func saw(_ p: Double) { lock.lock(); if p != pct { pct = p; last = Date() }; lock.unlock() }
            var idle: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
        }
        let state = State()
        let p = Process()
        p.executableURL = chdman
        p.arguments = ["verify", "-i", chd.path]
        p.environment = Converter.toolEnvironment
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        let buffer = LineBuffer { line in
            if let r = line.range(of: #"([0-9.]+)% complete"#, options: .regularExpression),
               let pct = Double(line[r].split(separator: "%")[0]) {
                state.saw(pct); progress(pct / 100)
            }
        }
        let stall = await MainActor.run { Converter.stallTimeout }
        let watchdog = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(5, stall / 2)))
                if state.idle > stall { p.terminate(); break }
            }
        }
        defer { watchdog.cancel() }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { buffer.feed(d) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: proc.terminationReason == .exit && proc.terminationStatus == 0)
            }
            do { try p.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: false)
            }
        }
    }
}

struct CleanupView: View {
    @ObservedObject private var m = Cleanup.shared
    @ObservedObject private var c = Converter.shared
    @State private var confirm = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find disc images that already have their CHDs, and move them to the Trash.")
                .foregroundStyle(.secondary)
            HStack {
                Text(m.folder?.path(percentEncoded: false) ?? "No folder chosen")
                    .lineLimit(1).truncationMode(.head)
                    .foregroundStyle(m.folder == nil ? .secondary : .primary)
                Spacer()
                Button("Choose Folder…", action: chooseFolder)
                    .disabled(m.phase == .scanning || m.phase == .working)
            }
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .alert("Move \(m.selected.count) item\(m.selected.count == 1 ? "" : "s") (\(formatBytes(m.selectedBytes))) to the Trash?",
               isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { m.run() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(m.verifyFirst
                 ? "Each CHD is verified first. Anything whose CHD fails is kept. You can put files back from the Trash."
                 : "You can put them back from the Trash.")
        }
    }

    @ViewBuilder private var content: some View {
        switch m.phase {
        case .idle:
            Text("Choose a folder to look in. Subfolders are included. A file counts as converted when its CHD (or, for a multi-disc PBP, every CHD in its .m3u) is next to it\(c.outputDir == nil ? "" : " or in your Save to: folder").")
                .foregroundStyle(.secondary)
        case .scanning:
            HStack { ProgressView().controlSize(.small); Text(m.status) }
        case .review:
            if m.items.isEmpty {
                Text("Nothing to clean up: no disc images here have a matching CHD.").foregroundStyle(.secondary)
            } else {
                review
            }
        case .working:
            VStack(alignment: .leading, spacing: 8) {
                Text(m.status).lineLimit(1).truncationMode(.middle)
                ProgressView(value: m.progress)
                Button("Stop") { m.cancel() }
            }
        case .done:
            VStack(alignment: .leading, spacing: 8) {
                Text(m.summary)
                HStack {
                    Button("Back to Converterator", action: backToMain)
                        .keyboardShortcut(.defaultAction)
                    Button("Clean Up Another Folder…", action: chooseFolder)
                }
                if !m.items.isEmpty { review }
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 8) {
            if m.ambiguous > 0 {
                Text("\(m.ambiguous) more left out: they share a CHD name with another file, so it's unclear which one the CHD was made from.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(m.items.count) converted item\(m.items.count == 1 ? "" : "s") found. \(m.selected.count) selected, \(formatBytes(m.selectedBytes)).")
                Spacer()
                Button("Select All") { for i in m.items.indices { m.items[i].include = true } }
                Button("Select None") { for i in m.items.indices { m.items[i].include = false } }
            }
            .font(.callout)
            List {
                ForEach($m.items) { $item in
                    Toggle(isOn: $item.include) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(itemDetail(item)).font(.caption)
                                .foregroundStyle(item.problem == nil ? Color.secondary : Color.red)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.source]) }
                        Button("Show CHD in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.chds) }
                    }
                }
            }
            HStack {
                Toggle("Verify each CHD before moving its originals", isOn: $m.verifyFirst)
                Spacer()
                Button("Move to Trash…") { confirm = true }
                    .disabled(m.selected.isEmpty || c.isRunning || (m.verifyFirst && c.chdman == nil))
                    // Return means "Back to Converterator" once the cleanup is done.
                    .keyboardShortcut(m.phase == .review ? .defaultAction : nil)
            }
            if c.isRunning {
                Text("Wait for the current batch to finish before cleaning up.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func itemDetail(_ item: Cleanup.Item) -> String {
        if let p = item.problem { return p }
        let extra = item.files.count - 1
        let files = extra > 0 ? " + \(extra) track file\(extra == 1 ? "" : "s")" : ""
        let chd = item.chds.count == 1 ? item.chds[0].lastPathComponent : "\(item.chds.count) CHDs"
        return "\(formatBytes(item.bytes))\(files) · converted to \(chd)"
    }

    /// Brings the main window forward (reopening it if it was closed) and closes this one.
    private func backToMain() {
        m.reset()   // next time, the window starts fresh
        openWindow(id: "main")
        dismissWindow(id: "cleanup")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Look Here"
        panel.message = "Choose a folder to look for disc images that already have CHDs"
        let window = NSApp.keyWindow
        let done: (NSApplication.ModalResponse) -> Void = { if $0 == .OK, let url = panel.url { m.scan(url) } }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}
