// Converterator — File → Check Against Redump… (CHDs and GameCube/Wii RVZs), and the shared tool runner.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

// MARK: - Check CHDs against Redump

/// Checks CHDs you already have: unpacks each to a temporary folder, hashes its tracks, and looks them
/// up in the Redump DATs. Matching CHDs can then be renamed to their Redump names.
@MainActor
final class CHDCheck: ObservableObject {
    static let shared = CHDCheck()

    struct Item: Identifiable {
        enum State { case waiting, checking, done, failed }
        let id = UUID()
        var url: URL
        var state: State = .waiting
        var progress = 0.0
        var result: RedumpResult?
        var error: String?
        var remembered = false   // result from an earlier check of the unchanged file

        /// The Redump name this CHD should have, if it matches and isn't already named that.
        var suggestedName: String? {
            guard case .match(let game) = result else { return nil }
            let name = Converter.safeFileName(game)
            return name == url.deletingPathExtension().lastPathComponent ? nil : name
        }
    }

    @Published var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published var message = ""
    /// Check again even CHDs that were checked before and haven't changed.
    @Published var recheck = false
    private var cancelled = false
    private var current: Process?

    var renameable: [Item] { items.filter { $0.suggestedName != nil } }

    func add(_ urls: [URL]) {
        let fm = FileManager.default
        var found: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let all = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? []
                found += all.filter { ["chd", "rvz"].contains($0.pathExtension.lowercased()) }
            } else if ["chd", "rvz"].contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        let have = Set(items.map { $0.url.standardizedFileURL })
        items += found.map(\.standardizedFileURL).filter { !have.contains($0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { Item(url: $0) }
        message = found.isEmpty ? "No .chd files found in what was added." : ""
    }

    func clear() { if !isRunning { items = []; message = "" } }

    func cancel() { cancelled = true; current?.terminate() }

    func start() {
        guard !isRunning, let chdman = Converter.shared.chdman else { return }
        let index = RedumpDB.shared.index
        guard !index.isEmpty else { message = "No Redump DATs are loaded yet. Download or add them in Settings."; return }
        isRunning = true
        cancelled = false
        message = ""
        Task {
            while !cancelled, let i = items.firstIndex(where: { $0.state == .waiting }) {
                let id = items[i].id
                if !recheck, let known = RedumpCache.lookup(items[i].url) {
                    items[i].result = known; items[i].state = .done; items[i].remembered = true
                    continue
                }
                items[i].state = .checking
                items[i].remembered = false
                let outcome = await CHDCheck.check(items[i].url, chdman: chdman, index: index,
                    started: { p in Task { @MainActor in self.current = p } },
                    progress: { p in Task { @MainActor in self.set(id) { $0.progress = p } } })
                set(id) {
                    switch outcome {
                    case .success(let r): $0.result = r; $0.state = .done; RedumpCache.store($0.url, r)
                    case .failure(let e): $0.error = self.cancelled ? "Stopped" : e.message; $0.state = .failed
                    }
                }
                if cancelled { set(id) { $0.state = .waiting; $0.error = nil; $0.progress = 0 } }
            }
            current = nil
            isRunning = false
            let done = items.filter { $0.state == .done }
            let matched = done.filter { $0.result?.isMatch == true }.count
            let known = done.filter(\.remembered).count
            if !done.isEmpty {
                message = "\(matched) of \(done.count) checked game\(done.count == 1 ? "" : "s") match Redump."
                    + (known > 0 ? " \(known) unchanged since an earlier check, so not unpacked again." : "")
            }
        }
    }

    private func set(_ id: UUID, _ change: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }

    /// Renames matching CHDs to their Redump names, and fixes any .m3u next to them that lists the old name.
    func renameMatches() {
        let fm = FileManager.default
        var renamed = 0, skipped: [String] = []
        for i in items.indices {
            guard let name = items[i].suggestedName else { continue }
            let old = items[i].url
            let new = old.deletingLastPathComponent().appendingPathComponent(name + "." + old.pathExtension)
            if fm.fileExists(atPath: new.path) { skipped.append(old.lastPathComponent); continue }
            do {
                try fm.moveItem(at: old, to: new)
                CHDCheck.fixPlaylists(in: old.deletingLastPathComponent(), from: old.lastPathComponent, to: new.lastPathComponent)
                ConversionLog.renamed(old, to: new)
                RedumpCache.move(old, to: new)
                DamageRecord.move(old, to: new)
                items[i].url = new
                renamed += 1
            } catch {
                skipped.append(old.lastPathComponent)
            }
        }
        message = "Renamed \(renamed) file\(renamed == 1 ? "" : "s")."
            + (skipped.isEmpty ? "" : " Left \(skipped.count) alone because a file with the new name already exists, or it couldn't be renamed.")
    }

    /// Replaces `from` with `to` on lines of every .m3u in `dir`.
    nonisolated static func fixPlaylists(in dir: URL, from: String, to: String) {
        let m3us = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "m3u" } ?? []
        for m in m3us {
            guard let text = try? String(contentsOf: m, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            let fixed = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == from ? to : $0 }
            if fixed != lines { try? fixed.joined(separator: "\n").write(to: m, atomically: true, encoding: .utf8) }
        }
    }

    struct CheckError: Error { let message: String }

    /// Unpacks one CHD to a temporary folder (track by track, the way Redump lists them), hashes the
    /// tracks and looks them up. The temporary files are always deleted.
    nonisolated static func check(_ chd: URL, chdman: URL, index: RedumpIndex,
                                  started: @escaping @Sendable (Process) -> Void,
                                  progress: @escaping @Sendable (Double) -> Void) async -> Result<RedumpResult, CheckError> {
        // A GameCube/Wii RVZ: dolphin-tool works out the SHA-1 of the disc inside, with nothing unpacked.
        if chd.pathExtension.lowercased() == "rvz" {
            guard let dolphin = Converter.findTool("dolphin-tool") else { return .failure(CheckError(message: "dolphin-tool is missing from the app")) }
            guard index.system.values.contains(where: { $0 == "gc" || $0 == "wii" }) else {
                return .failure(CheckError(message: "Turn on GameCube and Wii in Settings → Redump DAT files to check RVZs"))
            }
            progress(0)
            guard let sha = await Converter.discSHA1(chd, dolphin: dolphin) else {
                return .failure(CheckError(message: "dolphin-tool couldn't read this RVZ (is it damaged?)"))
            }
            progress(1)
            return .success(RedumpResult.lookup(sha1: sha, index: index))
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("converterator-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) }
        catch { return .failure(CheckError(message: "Can't create a temporary folder")) }

        let (infoStatus, infoLines) = await ToolRun.run(chdman, ["info", "-i", chd.path], started: started) { _ in }
        guard infoStatus == 0 else { return .failure(CheckError(message: "chdman couldn't read this CHD")) }
        // Room on the Mac's disk to unpack it.
        let logical = infoLines.compactMap(Converter.logicalSize).first ?? 0
        if let p = DiskSpace.problem(needs: logical, at: tmp) {
            return .failure(CheckError(message: p + " to unpack it. Free up some space and check again."))
        }
        let tags = infoLines.compactMap { line -> String? in
            guard let r = line.range(of: #"Tag='[^']{4}'"#, options: .regularExpression) else { return nil }
            return String(line[r].dropFirst(5).prefix(4))
        }

        let args: [String], tracks: () -> [URL]
        if tags.contains(where: { ["CHT2", "CHCD", "CHTR", "CHGD", "CHGT"].contains($0) }) {
            // --splitbin writes one .bin per track, like a Redump set. For a Dreamcast GD-ROM, chdman writes
            // Redump's layout too (single- and high-density areas, gaps inside the track files).
            args = ["extractcd", "-i", chd.path, "-o", tmp.appendingPathComponent("disc.cue").path, "-sb"]
            tracks = {
                ((try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension.lowercased() == "bin" }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
        } else if tags.contains("DVD ") {
            let iso = tmp.appendingPathComponent("disc.iso")
            args = ["extractdvd", "-i", chd.path, "-o", iso.path]
            tracks = { [iso] }
        } else {
            return .failure(CheckError(message: "Not a CD or DVD image"))
        }

        // Unpacking is about 60% of the time, hashing the rest.
        let (status, _) = await ToolRun.run(chdman, args, started: started) { progress($0 * 0.6) }
        guard status == 0 else {
            return .failure(CheckError(message: status == Converter.stalledStatus
                ? "chdman stopped responding — the CHD may be damaged" : "chdman couldn't unpack it (out of disk space, or a damaged CHD?)"))
        }
        let files = tracks()
        guard !files.isEmpty else { return .failure(CheckError(message: "Nothing was unpacked")) }
        let result = RedumpResult.check(tracks: files, index: index) { progress(0.6 + 0.4 * $0) }
        return .success(result)
    }
}

/// Runs a command-line tool, collecting its output lines and reporting chdman-style "45.3% complete"
/// progress. Stops the tool if its progress doesn't move for Converter.stallTimeout.
enum ToolRun {
    /// `watchdog: false` for tools that print no progress (xdelta3), which would otherwise look stalled.
    nonisolated static func run(_ exe: URL, _ args: [String], watchdog useWatchdog: Bool = true,
                                started: @escaping @Sendable (Process) -> Void = { _ in },
                                progress: @escaping @Sendable (Double) -> Void) async -> (Int32, [String]) {
        final class State: @unchecked Sendable {
            let lock = NSLock(); var last = Date(); var pct = -1.0; var lines: [String] = []; var stalled = false
            func add(_ line: String) -> Double? {
                lock.lock(); defer { lock.unlock() }
                lines.append(line)
                guard let r = line.range(of: #"([0-9.]+)% complete"#, options: .regularExpression),
                      let p = Double(line[r].split(separator: "%")[0]) else { return nil }
                if p != pct { pct = p; last = Date() }
                return p / 100
            }
            var idle: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
            func markStalled() { lock.lock(); stalled = true; lock.unlock() }
            func finish(_ status: Int32) -> (Int32, [String]) {
                lock.lock(); defer { lock.unlock() }
                return (stalled ? Converter.stalledStatus : status, lines)
            }
        }
        let state = State()
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = Converter.toolEnvironment
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        let buffer = LineBuffer { line in if let f = state.add(line) { progress(f) } }
        let stall = await MainActor.run { Converter.stallTimeout }
        let watchdog = Task.detached {
            while useWatchdog && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(5, stall / 2)))
                if state.idle > stall { state.markStalled(); p.terminate(); break }
            }
        }
        defer { watchdog.cancel() }
        let status: Int32 = await withCheckedContinuation { cont in
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { buffer.feed(d) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.feed(pipe.fileHandleForReading.readDataToEndOfFile())
                buffer.flush()
                cont.resume(returning: proc.terminationStatus)
            }
            do { try p.run(); started(p) } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: -1)
            }
        }
        return state.finish(status)
    }
}

struct CHDCheckView: View {
    @ObservedObject private var m = CHDCheck.shared
    @ObservedObject private var redump = RedumpDB.shared
    @ObservedObject private var c = Converter.shared
    @State private var confirmRename = false
    @State private var dropTargeted = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check CHDs and GameCube/Wii RVZs you already have against Redump's list of known good dumps. Each CHD is unpacked to a temporary folder, checked, and the temporary files deleted, so it takes a little while and needs free space for one disc. An RVZ is checked without unpacking (turn on GameCube and Wii in Settings → Redump DAT files).")
                .foregroundStyle(.secondary)
            if redump.index.isEmpty {
                HStack {
                    Label(redump.isLoading || redump.isDownloading ? "Loading Redump DATs…" : "No Redump DATs loaded yet.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    SettingsLink { Text("Open Settings…") }
                }
            }
            HStack {
                Button("Add Files…") { pick(folders: false) }
                Button("Choose Folder…") { pick(folders: true) }
                Button("Clear") { m.clear() }.disabled(m.isRunning || m.items.isEmpty)
                Spacer()
                Toggle("Check again if checked before", isOn: $m.recheck).disabled(m.isRunning)
                if m.isRunning {
                    Button("Stop") { m.cancel() }
                } else {
                    Button("Check") { m.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!m.items.contains { $0.state == .waiting } || redump.index.isEmpty || c.chdman == nil)
                }
            }
            .disabled(false)
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).opacity(dropTargeted ? 1 : 0))
                .dropDestination(for: URL.self) { urls, _ in m.add(urls); return true } isTargeted: { dropTargeted = $0 }
            if !m.message.isEmpty { Text(m.message).font(.callout) }
            HStack {
                Button("Rename \(m.renameable.count) to Redump Names…") { confirmRename = true }
                    .disabled(m.renameable.isEmpty || m.isRunning)
                Spacer()
                Button("Back to Converterator") {
                    openWindow(id: "main")
                    dismissWindow(id: "chdcheck")
                }
            }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 440)
        .alert("Rename \(m.renameable.count) CHD\(m.renameable.count == 1 ? "" : "s") to their Redump names?", isPresented: $confirmRename) {
            Button("Rename") { m.renameMatches() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each matching CHD or RVZ gets its Redump game's name, for example “Armored Core (USA).chd”. Any .m3u playlist next to it is updated. A file is left alone if one with the new name already exists.")
        }
    }

    private var list: some View {
        List {
            if m.items.isEmpty {
                Text("Drop .chd files or folders here.").foregroundStyle(.secondary)
            }
            ForEach(m.items) { item in
                HStack(spacing: 10) {
                    icon(item).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        if item.state == .checking { ProgressView(value: item.progress).controlSize(.small) }
                        Text(detail(item)).font(.caption)
                            .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                            .lineLimit(2)
                    }
                }
                .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
            }
        }
    }

    @ViewBuilder private func icon(_ item: CHDCheck.Item) -> some View {
        switch item.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .done:
            if item.result?.isMatch == true { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
            else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }

    private func detail(_ item: CHDCheck.Item) -> String {
        switch item.state {
        case .waiting: return "Waiting"
        case .checking: return item.progress < 0.6 ? "Unpacking — \(Int(item.progress / 0.6 * 100))%" : "Checking — \(Int((item.progress - 0.6) / 0.4 * 100))%"
        case .failed: return item.error ?? "Failed"
        case .done:
            guard let r = item.result else { return "" }
            var text = r.long.replacingOccurrences(of: "Redump: ", with: "")
            if item.remembered { text += " · checked before" }
            if let n = item.suggestedName { text += " · can be renamed to “\(n).chd”" }
            return text
        }
    }

    private func pick(folders: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        if !folders { panel.allowedContentTypes = [UTType(filenameExtension: "chd"), UTType(filenameExtension: "rvz")].compactMap { $0 } }
        panel.message = folders ? "Choose a folder of CHDs and RVZs (subfolders are included)" : "Choose CHD or RVZ files to check"
        let done: (NSApplication.ModalResponse) -> Void = { if $0 == .OK { m.add(panel.urls) } }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}
